import 'dart:async';

import 'package:attractor/attractor.dart';
import 'package:test/test.dart';

import 'package:tina/pipeline/launch_workflow_tool.dart';
import 'package:tina/pipeline/workflow_supervisor.dart';
import '../helpers/fake_agent_sink.dart';
import 'package:tina/pipeline/pipeline_runner.dart';

/// Pump the event loop until [pred] holds, or time out (the supervisor's
/// report-back and status updates run on the background run future).
Future<void> _pumpUntil(bool Function() pred, {int iterations = 200}) async {
  for (var i = 0; i < iterations; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (pred()) return;
  }
  throw TimeoutException('pumpUntil timed out');
}

/// A scripted `RunWorkflow` stand-in recording each call's arguments. Each run
/// stays in flight until its [control] completer resolves or its cancel signal
/// fires (→ `Outcome.fail('cancelled')`, mirroring the engine).
class _ScriptedRunner {
  final List<({String name, String? input, String? history})> calls = [];
  final List<Completer<PipelineRunResult>> controls = [];

  RunWorkflow build() {
    return ({
      required workflowName,
      required sink,
      input,
      history,
      cancelSignal,
      onEvent,
    }) async {
      calls.add((name: workflowName, input: input, history: history));
      final done = Completer<PipelineRunResult>();
      controls.add(done);
      if (cancelSignal == null) return done.future;
      return Future.any<PipelineRunResult>([
        done.future,
        cancelSignal.then((_) =>
            PipelineRunResult(outcome: Outcome.fail('cancelled'), runDir: '')),
      ]);
    };
  }
}

void main() {
  group('LaunchWorkflowTool', () {
    test('launch_workflow launches in the background and returns immediately '
        '(does not await the run)', () async {
      final runner = _ScriptedRunner();
      final supervisor = WorkflowSupervisor(run: runner.build());
      final tool = LaunchWorkflowTool(
          supervisor: supervisor,
          conversationId: 'conv-1',
          sink: FakeAgentSink());

      final res = await tool.execute({'input': 'fix the bug', 'workflow': 'lint'});

      // The tool returned even though the run is still in flight.
      expect(res.isError, isFalse);
      expect(res.content, contains('Launched workflow "lint"'));
      expect(res.content, contains('run '));

      // Arguments were forwarded: workflow name, input, and the conversationId
      // used to route the completion turn back to the launching chat.
      expect(runner.calls.single.name, 'lint');
      expect(runner.calls.single.input, 'fix the bug');
      expect(supervisor.active.single.conversationId, 'conv-1');
      expect(supervisor.active.single.status, WorkflowRunStatus.running);

      // Let the run finish so the test tears down cleanly.
      runner.controls.single.complete(
          const PipelineRunResult(outcome: Outcome.success(), runDir: ''));
      await _pumpUntil(() => supervisor.active.isEmpty);
    });

    test('defaults workflow to "default" when omitted or blank', () async {
      final runner = _ScriptedRunner();
      final supervisor = WorkflowSupervisor(run: runner.build());
      final tool = LaunchWorkflowTool(
          supervisor: supervisor,
          conversationId: 'conv-1',
          sink: FakeAgentSink());

      await tool.execute({'input': 'do the thing'});
      expect(runner.calls.single.name, 'default');

      await tool.execute({'input': 'do the thing', 'workflow': '   '});
      expect(runner.calls.last.name, 'default');

      runner.controls.forEach((c) => c.complete(
          const PipelineRunResult(outcome: Outcome.success(), runDir: '')));
      await _pumpUntil(() => supervisor.active.isEmpty);
    });

    test('requires a non-empty input', () async {
      final runner = _ScriptedRunner();
      final supervisor = WorkflowSupervisor(run: runner.build());
      final tool = LaunchWorkflowTool(
          supervisor: supervisor,
          conversationId: 'conv-1',
          sink: FakeAgentSink());

      final res = await tool.execute({'input': '   '});

      expect(res.isError, isTrue);
      expect(res.content, contains('input'));
      // Nothing was launched.
      expect(runner.calls, isEmpty);
    });
  });

  group('StopWorkflowTool', () {
    test('stop_workflow cancels the most recent running launch when no run_id '
        'is given', () async {
      final runner = _ScriptedRunner();
      final supervisor = WorkflowSupervisor(run: runner.build());
      final tool = StopWorkflowTool(supervisor: supervisor);
      final sink = FakeAgentSink();

      supervisor.launch(name: 'a', conversationId: 'conv-1', sink: sink);
      final b =
          supervisor.launch(name: 'b', conversationId: 'conv-1', sink: sink);

      final res = await tool.execute({});

      expect(res.isError, isFalse);
      expect(res.content, contains('Stopped workflow "b"'));
      expect(res.content, contains('run ${b.id}'));
      await _pumpUntil(() => b.status == WorkflowRunStatus.cancelled);
      expect(b.status, WorkflowRunStatus.cancelled);

      // Clean up run a.
      supervisor.stopAll();
      await _pumpUntil(() => supervisor.active.isEmpty);
    });

    test('stop_workflow with a run_id stops that specific run', () async {
      final runner = _ScriptedRunner();
      final supervisor = WorkflowSupervisor(run: runner.build());
      final tool = StopWorkflowTool(supervisor: supervisor);
      final sink = FakeAgentSink();

      final a =
          supervisor.launch(name: 'a', conversationId: 'conv-1', sink: sink);
      supervisor.launch(name: 'b', conversationId: 'conv-1', sink: sink);

      final res = await tool.execute({'run_id': a.id});

      expect(res.isError, isFalse);
      expect(res.content, contains('Stopped workflow "a"'));
      await _pumpUntil(() => a.status == WorkflowRunStatus.cancelled);
      expect(a.status, WorkflowRunStatus.cancelled);

      supervisor.stopAll();
      await _pumpUntil(() => supervisor.active.isEmpty);
    });

    test('stop_workflow with nothing running reports it', () async {
      final supervisor = WorkflowSupervisor(run: _ScriptedRunner().build());
      final tool = StopWorkflowTool(supervisor: supervisor);

      final res = await tool.execute({});

      expect(res.isError, isFalse);
      expect(res.content, contains('No running workflow to stop.'));
    });

    test('stop_workflow with an unknown run_id reports it is not running',
        () async {
      final supervisor = WorkflowSupervisor(run: _ScriptedRunner().build());
      final tool = StopWorkflowTool(supervisor: supervisor);

      final res = await tool.execute({'run_id': 'ghost'});

      expect(res.isError, isFalse);
      expect(res.content, contains('ghost'));
      expect(res.content, contains('not running'));
    });
  });
}
