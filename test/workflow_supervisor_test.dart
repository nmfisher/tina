import 'dart:async';
import 'dart:io';

import 'package:attractor/attractor.dart';
import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

import '../lib/pipeline/workflow_supervisor.dart';
import 'helpers/fake_agent_sink.dart';

/// Pump the event loop until [pred] holds, or time out. The supervisor's
/// report-back runs in a `.then` on the background run future, so tests trip a
/// completion and pump until the report notice has landed.
Future<void> _pumpUntil(bool Function() pred, {int iterations = 200}) async {
  for (var i = 0; i < iterations; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    if (pred()) return;
  }
  throw TimeoutException('pumpUntil timed out');
}

/// A scripted runner stand-in for the `RunWorkflow` seam. Each launch records
/// its arguments, emits a fake "node_started" notice to the sink (so tests can
/// assert monitoring), and resolves to either a test-supplied outcome or — when
/// its cancel signal fires — `Outcome.fail('cancelled')` (mirroring the engine).
class _ScriptedRunner {
  final List<({String name, String? input})> calls = [];
  final List<_RunControl> controls = [];

  /// When true, each launch emits a scripted `node_started` event for node
  /// `x` through the run's [PipelineEventListener] before running.
  bool emitEvent = true;

  RunWorkflow build() {
    return ({
      required workflowName,
      required sink,
      input,
      history,
      cancelSignal,
      onEvent,
    }) async {
      calls.add((name: workflowName, input: input));
      final control = _RunControl(sink);
      controls.add(control);
      // Simulate an engine progress event surfacing to the chat host.
      sink.notice('▶ scripted_node', kind: NoticeKind.info);
      if (emitEvent) {
        onEvent?.call(const PipelineEvent('node_started', nodeId: 'x'));
      }
      if (cancelSignal == null) {
        return control.done.future;
      }
      return Future.any<Outcome>([
        control.done.future,
        cancelSignal.then((_) => Outcome.fail('cancelled')),
      ]);
    };
  }
}

class _RunControl {
  final AgentSink sink;
  final Completer<Outcome> done = Completer<Outcome>();
  _RunControl(this.sink);
}

void main() {
  group('WorkflowSupervisor', () {
    test('launch returns immediately with a running handle (does not block)',
        () async {
      final runner = _ScriptedRunner();
      final supervisor = WorkflowSupervisor(run: runner.build());
      final sink = FakeAgentSink();

      final run = supervisor.launch(
          name: 'default',
          conversationId: 'conv-1',
          sink: sink,
          input: 'fix the bug');

      // The handle is returned BEFORE the run completes (done is still open).
      expect(run.workflowName, 'default');
      expect(run.conversationId, 'conv-1');
      expect(run.status, WorkflowRunStatus.running);
      expect(supervisor.active, contains(run));
      expect(supervisor.active.single, run);
      expect(runner.calls.single.name, 'default');
      expect(runner.calls.single.input, 'fix the bug');

      // Let it finish so the test tears down cleanly.
      runner.controls.single.done.complete(const Outcome.success());
      await _pumpUntil(() => run.status != WorkflowRunStatus.running);
    });

    test('a node event from the run surfaces to the chat sink (monitoring)',
        () async {
      final runner = _ScriptedRunner();
      final supervisor = WorkflowSupervisor(run: runner.build());
      final sink = FakeAgentSink();

      final run =
          supervisor.launch(name: 'default', conversationId: 'conv-1', sink: sink);

      // The scripted runner emits '▶ scripted_node' to the sink — the same sink
      // the chat host would be in the real wiring.
      await _pumpUntil(
          () => sink.notices.any((n) => n.message.contains('scripted_node')));

      runner.controls.single.done.complete(const Outcome.success());
      await _pumpUntil(() => run.status != WorkflowRunStatus.running);
      expect(sink.notices.any((n) => n.message.contains('scripted_node')), isTrue);
    });

    test('a completed run reports success back to the chat sink', () async {
      final runner = _ScriptedRunner();
      final supervisor = WorkflowSupervisor(run: runner.build());
      final sink = FakeAgentSink();

      final run = supervisor.launch(
          name: 'default',
          conversationId: 'conv-1',
          sink: sink,
          goal: 'refactor the auth module');

      // The launch is announced.
      expect(
          sink.notices.any((n) =>
              n.message.contains('launched') && n.message.contains('default')),
          isTrue);

      runner.controls.single.done.complete(const Outcome.success());
      await _pumpUntil(() => run.status == WorkflowRunStatus.completed);

      expect(run.outcome?.status, StageStatus.success);
      expect(run.goal, 'refactor the auth module');
      // Report-back notice posted on completion.
      expect(
          sink.notices.any((n) =>
              n.message.contains('complete') && n.message.contains('default')),
          isTrue);
      // The run is no longer active once finished.
      expect(supervisor.active, isNot(contains(run)));
    });

    test('a completed run fires onComplete with the finished run', () async {
      final runner = _ScriptedRunner();
      WorkflowRun? completed;
      final supervisor = WorkflowSupervisor(
        run: runner.build(),
        onComplete: (run) => completed = run,
      );
      final sink = FakeAgentSink();

      final run =
          supervisor.launch(name: 'default', conversationId: 'conv-1', sink: sink);
      runner.controls.single.done.complete(const Outcome.success());
      await _pumpUntil(() => completed != null);

      expect(completed, same(run));
      expect(completed?.status, WorkflowRunStatus.completed);
      // Fired AFTER the report notice, so the chat saw the ✔ before the hook.
      expect(
          sink.notices.any(
              (n) => n.message.contains('complete') && n.message.contains('default')),
          isTrue);
    });

    test('onLaunch fires synchronously after the launch notice', () async {
      final runner = _ScriptedRunner();
      WorkflowRun? launched;
      var noticeVisibleAtHook = false;
      final sink = FakeAgentSink();
      final supervisor = WorkflowSupervisor(
        run: runner.build(),
        onLaunch: (run) {
          launched = run;
          // The launch notice was posted before the hook ran.
          noticeVisibleAtHook = sink.notices.any((n) => n.message.contains('launched'));
        },
      );

      final run = supervisor.launch(
          name: 'default', conversationId: 'conv-1', sink: sink);

      // The hook ran synchronously inside launch with the run handle — so a
      // host can open a live view before any engine event can arrive.
      expect(launched, same(run));
      expect(noticeVisibleAtHook, isTrue);

      runner.controls.single.done.complete(const Outcome.success());
      await _pumpUntil(() => run.status != WorkflowRunStatus.running);
    });

    test('a run event updates nodeStatus and reaches the external listener',
        () async {
      final runner = _ScriptedRunner();
      final supervisor = WorkflowSupervisor(run: runner.build());
      final sink = FakeAgentSink();
      final seen = <PipelineEvent>[];

      final run = supervisor.launch(
          name: 'default',
          conversationId: 'conv-1',
          sink: sink,
          onEvent: seen.add);

      await _pumpUntil(() => run.nodeStatus.containsKey('x'));
      expect(run.nodeStatus['x'], NodeRunStatus.running);
      expect(seen.single.kind, 'node_started');
      expect(seen.single.nodeId, 'x');

      runner.controls.single.done.complete(const Outcome.success());
      await _pumpUntil(() => run.status != WorkflowRunStatus.running);
    });

    test('a synchronously-completing run records every event in nodeStatus '
        'and fires onFinished', () async {
      final supervisor = WorkflowSupervisor(
        run: ({
          required workflowName,
          required sink,
          input,
          history,
          cancelSignal,
          onEvent,
        }) async {
          onEvent?.call(const PipelineEvent('node_started', nodeId: 'a'));
          onEvent?.call(const PipelineEvent('node_completed', nodeId: 'a'));
          return const Outcome.success();
        },
      );
      var finished = false;
      final run = supervisor.launch(
          name: 'default', conversationId: 'conv-1', sink: FakeAgentSink());
      run.onFinished = () => finished = true;

      await _pumpUntil(() => run.status == WorkflowRunStatus.completed);
      // The internal listener never misses, even for sync emissions.
      expect(run.nodeStatus['a'], NodeRunStatus.done);
      expect(finished, isTrue);
    });

    test('onFinished fires on the thrown-runner path too', () async {
      final supervisor = WorkflowSupervisor(
        run: ({
          required workflowName,
          required sink,
          input,
          history,
          cancelSignal,
          onEvent,
        }) async =>
            throw StateError('boom'),
      );
      var finished = false;
      final run = supervisor.launch(
          name: 'default', conversationId: 'conv-1', sink: FakeAgentSink());
      run.onFinished = () => finished = true;

      await _pumpUntil(() => run.status == WorkflowRunStatus.failed);
      expect(finished, isTrue);
    });

    test('a runner that throws (e.g. missing workflow file) is reported as a '
        'failed run and fires onComplete', () async {
      final sink = FakeAgentSink();
      WorkflowRun? completed;
      final supervisor = WorkflowSupervisor(
        run: ({
          required workflowName,
          required sink,
          input,
          history,
          cancelSignal,
          onEvent,
        }) async =>
            throw FileSystemException('workflow not found', 'ghost.dot'),
        onComplete: (run) => completed = run,
      );

      final run = supervisor.launch(
          name: 'ghost', conversationId: 'conv-1', sink: sink);
      await _pumpUntil(() => run.status == WorkflowRunStatus.failed);

      expect(run.status, WorkflowRunStatus.failed);
      expect(run.outcome?.failureReason, contains('workflow not found'));
      final report = sink.notices.lastWhere((n) => n.message.contains('failed'));
      expect(report.kind, NoticeKind.error);
      expect(report.message, contains('workflow not found'));
      // The completion turn still fires, so the agent can report the failure.
      expect(completed, same(run));
    });

    test('a failed run reports the failure reason back', () async {
      final runner = _ScriptedRunner();
      final supervisor = WorkflowSupervisor(run: runner.build());
      final sink = FakeAgentSink();

      final run =
          supervisor.launch(name: 'default', conversationId: 'conv-1', sink: sink);

      runner.controls.single.done
          .complete(Outcome.fail('goal gate "review" unsatisfied'));
      await _pumpUntil(() => run.status == WorkflowRunStatus.failed);

      expect(run.status, WorkflowRunStatus.failed);
      final report =
          sink.notices.lastWhere((n) => n.message.contains('failed'));
      expect(report.kind, NoticeKind.error);
      expect(report.message, contains('goal gate "review" unsatisfied'));
    });

    test('stop(id) cancels the run and reports it cancelled', () async {
      final runner = _ScriptedRunner();
      final supervisor = WorkflowSupervisor(run: runner.build());
      final sink = FakeAgentSink();

      final run =
          supervisor.launch(name: 'default', conversationId: 'conv-1', sink: sink);
      expect(supervisor.stop(run.id), isTrue);

      await _pumpUntil(() => run.status == WorkflowRunStatus.cancelled);

      expect(run.status, WorkflowRunStatus.cancelled);
      expect(run.outcome?.failureReason, 'cancelled');
      final report =
          sink.notices.lastWhere((n) => n.message.contains('cancelled'));
      expect(report.message, contains('default'));
    });

    test('stop() with no id cancels the most recent active run', () async {
      final runner = _ScriptedRunner();
      final supervisor = WorkflowSupervisor(run: runner.build());

      final sinkA = FakeAgentSink();
      final sinkB = FakeAgentSink();
      final runA = supervisor.launch(
          name: 'default', conversationId: 'conv-1', sink: sinkA);
      final runB = supervisor.launch(
          name: 'other', conversationId: 'conv-2', sink: sinkB);

      // stop() targets the newest launch (runB).
      expect(supervisor.stop(), isTrue);

      await _pumpUntil(() => runB.status == WorkflowRunStatus.cancelled);
      expect(runB.status, WorkflowRunStatus.cancelled);
      // runA is still running.
      expect(runA.status, WorkflowRunStatus.running);

      // Clean up runA so the test tears down cleanly.
      supervisor.stop(runA.id);
      await _pumpUntil(() => runA.status == WorkflowRunStatus.cancelled);
    });

    test('stop() on nothing running is a no-op (returns false)', () async {
      final supervisor = WorkflowSupervisor(run: _ScriptedRunner().build());
      expect(supervisor.stop(), isFalse);
    });

    test('stopAll cancels every active run', () async {
      final runner = _ScriptedRunner();
      final supervisor = WorkflowSupervisor(run: runner.build());

      final a = supervisor.launch(
          name: 'a', conversationId: 'conv-1', sink: FakeAgentSink());
      final b = supervisor.launch(
          name: 'b', conversationId: 'conv-2', sink: FakeAgentSink());
      supervisor.stopAll();

      await _pumpUntil(() => supervisor.active.isEmpty);
      expect(a.status, WorkflowRunStatus.cancelled);
      expect(b.status, WorkflowRunStatus.cancelled);
    });
  });
}
