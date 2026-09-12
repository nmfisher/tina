import 'dart:async';
import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_tool.dart';
import '../helpers/memory_process_runner.dart';

void main() {
  group('ToolExecutor', () {
    test('malformed arguments return an error result without executing the tool',
        () async {
      final sink = FakeAgentSink();
      var executed = false;
      final executor = ToolExecutor(
        policy: PermissionPolicy(),
        asker: (_) async => PermissionResponse.denyOnce,
        sink: sink,
        state: ToolCallState(),
        cancelSignal: Completer<void>().future,
      );
      final outcome = await executor.execute(
        use: const ToolUseBlock(
          id: 'u1',
          name: 'fake',
          input: {},
          argumentsParseError: "Unexpected character '\'' at offset 3",
        ),
        stepTools: ToolRegistry([
          FakeTool('fake', (_) async {
            executed = true;
            return const ToolResult('ran');
          }),
        ]).forStep(),
        step: 0,
        isCancelled: () => false,
      );
      expect(executed, isFalse);
      expect(outcome.result.isError, isTrue);
      expect(outcome.result.toolUseId, 'u1');
      expect(
          outcome.result.content,
          contains('was discarded: its arguments were not valid JSON '
              "(Unexpected character '\'' at offset 3)"));
      expect(outcome.result.content, contains(r'written as \"'));
      expect(outcome.interruptedInFlight, isFalse);
      expect(sink.notices.single.kind, NoticeKind.warning);
      expect(sink.toolStarts, isEmpty);
    });

    test('unknown tool returns an error result and an error notice', () async {
      final sink = FakeAgentSink();
      final executor = ToolExecutor(
        policy: PermissionPolicy(),
        asker: (_) async => PermissionResponse.denyOnce,
        sink: sink,
        state: ToolCallState(),
        cancelSignal: Completer<void>().future,
      );
      final outcome = await executor.execute(
        use: const ToolUseBlock(id: 'u1', name: 'nope', input: {}),
        stepTools: ToolRegistry([
          FakeTool.noOp('fake'),
        ]).forStep(),
        step: 0,
        isCancelled: () => false,
      );
      expect(outcome.result.isError, isTrue);
      expect(outcome.result.content, 'Unknown tool: nope');
      expect(outcome.interruptedInFlight, isFalse);
      expect(sink.notices.single.kind, NoticeKind.error);
      expect(sink.toolStarts, isEmpty);
    });

    test('repeated denials attach the circuit-breaker note on the threshold '
        'denial', () async {
      final sink = FakeAgentSink();
      final executor = ToolExecutor(
        policy: PermissionPolicy(defaults: {
          'fake': PermissionDecision.deny,
        }),
        asker: (_) async => PermissionResponse.denyOnce,
        sink: sink,
        state: ToolCallState(),
        cancelSignal: Completer<void>().future,
      );
      final tools = ToolRegistry([FakeTool.noOp('fake')]).forStep();

      Future<ToolCallOutcome> call(String id) => executor.execute(
            use: ToolUseBlock(id: id, name: 'fake', input: const {}),
            stepTools: tools,
            step: 0,
            isCancelled: () => false,
          );

      final first = await call('u1');
      expect(first.result.isError, isTrue);
      expect(first.result.content, contains('Denied by permission policy.'));
      expect(first.result.content, isNot(contains('consecutive')));

      final second = await call('u2');
      expect(second.result.content, isNot(contains('consecutive')));

      final third = await call('u3');
      expect(third.result.content, contains('3 consecutive fake denials'));
      expect(third.result.content,
          contains('Stop calling it; proceed with the allowed tools'));
      // One warning notice for the crossing; the plain denial notices stay info.
      expect(sink.notices.where((n) => n.kind == NoticeKind.warning).length, 1);
      expect(sink.notices.last.message, contains('circuit-breaker notice'));
    });

    test('an allowed call resets the denial streak', () async {
      final sink = FakeAgentSink();
      var deny = true;
      final executor = ToolExecutor(
        policy: PermissionPolicy(defaults: {
          'fake': PermissionDecision.ask,
        }),
        asker: (_) async =>
            deny ? PermissionResponse.denyOnce : PermissionResponse.allowOnce,
        sink: sink,
        state: ToolCallState(),
        cancelSignal: Completer<void>().future,
      );
      final tools = ToolRegistry([FakeTool.noOp('fake')]).forStep();
      Future<ToolCallOutcome> call(String id) => executor.execute(
            use: ToolUseBlock(id: id, name: 'fake', input: const {}),
            stepTools: tools,
            step: 0,
            isCancelled: () => false,
          );

      // Two denials (streak = 2, below the threshold)…
      await call('u1');
      await call('u2');
      // …an allowed call resets the per-tool counter…
      deny = false;
      final allowed = await call('u3');
      expect(allowed.result.isError, isFalse);
      expect(allowed.result.content, 'ok');
      // …so two further denials still sit below the threshold: no note.
      deny = true;
      await call('u4');
      final fourth = await call('u5');
      expect(fourth.result.content, isNot(contains('consecutive')));
    });

    test('verifier verdict is appended on success; a throwing verifier never '
        'breaks the result', () async {
      final sink = FakeAgentSink();
      final verifier = (tool, input) async =>
          tool == 'fake' ? 'VERDICT: problem found' : null;
      final state = ToolCallState();
      final executor = ToolExecutor(
        policy: PermissionPolicy(defaults: {
          'fake': PermissionDecision.allow,
        }),
        asker: (_) async => PermissionResponse.denyOnce,
        sink: sink,
        state: state,
        resultVerifier: verifier,
        cancelSignal: Completer<void>().future,
      );
      final tools = ToolRegistry([FakeTool.noOp('fake')]).forStep();
      Future<ToolCallOutcome> call(String id) => executor.execute(
            use: ToolUseBlock(id: id, name: 'fake', input: const {}),
            stepTools: tools,
            step: 0,
            isCancelled: () => false,
          );

      final ok = await call('u1');
      expect(ok.result.isError, isFalse);
      expect(ok.result.content, 'ok\nVERDICT: problem found');

      // An error result skips the gate entirely.
      final toolsErr = ToolRegistry([
        FakeTool('fake', (_) async => const ToolResult('boom', isError: true)),
      ]).forStep();
      final err = await executor.execute(
        use: const ToolUseBlock(id: 'u2', name: 'fake', input: {}),
        stepTools: toolsErr,
        step: 0,
        isCancelled: () => false,
      );
      expect(err.result.isError, isTrue);
      expect(err.result.content, 'boom');

      // A throwing verifier ships the tool content unchanged…
      final flakyExecutor = ToolExecutor(
        policy: PermissionPolicy(defaults: {
          'fake': PermissionDecision.allow,
        }),
        asker: (_) async => PermissionResponse.denyOnce,
        sink: sink,
        state: ToolCallState(),
        resultVerifier: (tool, input) async =>
            throw StateError('verifier exploded'),
        cancelSignal: Completer<void>().future,
      );
      final flaky = await flakyExecutor.execute(
        use: const ToolUseBlock(id: 'u3', name: 'fake', input: {}),
        stepTools: tools,
        step: 0,
        isCancelled: () => false,
      );
      expect(flaky.result.isError, isFalse);
      expect(flaky.result.content, 'ok');
    });

    test('an extra guard denies a call before the sandbox access request '
        'runs (no ask prompt, no execute)', () async {
      final sink = FakeAgentSink();
      var prompts = 0;
      var ran = false;
      final temp = Directory.systemTemp.createTempSync('tina-guard-sandbox-');
      final cache = Directory('${temp.path}/cache')..createSync();
      addTearDown(() => temp.deleteSync(recursive: true));
      // A sandboxed bash whose writablePaths request WOULD produce an access
      // request (the default policy treats /tmp as external) — the guard must
      // deny upstream of it.
      final bash = BashTool(
        processRunner: SandboxedProcessRunner(
          projectRoot: temp.path,
          inner: MemoryProcessRunner((_, __) {
            ran = true;
            return MemoryRunningProcess(stdoutChunks: ['ok']);
          }),
          backend: SandboxBackend.bwrap,
          accessPolicy: SandboxAccessPolicy(),
        ),
        projectRoot: temp.path,
      );
      final executor = ToolExecutor(
        policy: PermissionPolicy(defaults: {
          'bash': PermissionDecision.allow,
        }),
        asker: (_) async {
          prompts++;
          return PermissionResponse.denyOnce;
        },
        sink: sink,
        state: ToolCallState(),
        cancelSignal: Completer<void>().future,
        executionGuards: [_DenyBashGuard('no shell while the operator is away')],
      );
      final outcome = await executor.execute(
        use: ToolUseBlock(id: 'u1', name: 'bash', input: {
          'command': 'echo test',
          'writablePaths': [cache.path],
          'accessReason': 'The launcher updates its cache metadata.',
        }),
        stepTools: ToolRegistry([bash]).forStep(),
        step: 0,
        isCancelled: () => false,
      );
      expect(outcome.result.isError, isTrue);
      expect(outcome.result.content, 'no shell while the operator is away');
      expect(prompts, 0,
          reason: 'the guard denies before the ask gate is reached');
      expect(ran, isFalse, reason: 'the guard denies before execution');
      expect(sink.toolStarts, isEmpty);
    });

    test('approved arguments are sealed: mutating the live input during the '
        'approval wait cannot change what executes', () async {
      final sink = FakeAgentSink();
      final seen = <String>[];
      // The asker approves while the caller's live map is swapped under it.
      final asker = _SwapInputAsker(seen);
      final bash = BashTool(
        processRunner: MemoryProcessRunner((executable, arguments) {
          seen.add('executed: ${arguments.join(' ')}');
          return MemoryRunningProcess(stdoutChunks: ['ok']);
        }),
        projectRoot: Directory.systemTemp.path,
      );
      final executor = ToolExecutor(
        policy: PermissionPolicy(defaults: {
          'bash': PermissionDecision.ask,
        }),
        asker: asker.ask,
        sink: sink,
        state: ToolCallState(),
        cancelSignal: Completer<void>().future,
      );
      // The live map belongs to the test; the executor must never re-read it
      // after snapshotting.
      final liveInput = <String, dynamic>{
        'command': 'echo approved',
      };
      var firstAskSeen = false;
      late ToolUseBlock use;
      void armSwap() {
        if (firstAskSeen) return;
        firstAskSeen = true;
        scheduleMicrotask(() {
          liveInput['command'] = 'rm -rf /tmp/unapproved';
        });
      }

      asker.onPrompt = (p) {
        armSwap();
      };
      use = ToolUseBlock(id: 'u1', name: 'bash', input: liveInput);
      final outcome = await executor.execute(
        use: use,
        stepTools: ToolRegistry([bash]).forStep(),
        step: 0,
        isCancelled: () => false,
      );
      expect(outcome.result.isError, isFalse,
          reason: 'the approval itself must still stand');
      expect(seen.where((s) => s.startsWith('asked:')), ['asked: echo approved'],
          reason: 'exactly one ask, prompted with the sealed arguments');
      expect(seen, contains('executed: -c echo approved'),
          reason: 'the snapshot taken BEFORE the ask is what runs — the '
              'swapped command must never execute');
      expect(seen.any((s) => s.contains('unapproved')), isFalse,
          reason: 'the mutated command never reaches prompt, policy, or '
              'execution');
    });
  });
}

/// An extra guard that denies every bash call with a fixed message.
class _DenyBashGuard implements ToolGuard {
  final String message;
  const _DenyBashGuard(this.message);

  @override
  String? block(String toolName, Map<String, dynamic> input) =>
      toolName == 'bash' ? message : null;
}

/// An asker that approves once and lets the test swap the caller's live
/// input map mid-wait (via [onPrompt]) — reproducing the
/// approve-"approved"-execute-"unapproved" race the sealed-snapshot fix
/// closes.
class _SwapInputAsker {
  final List<String> seen;
  _SwapInputAsker(this.seen);

  void Function(PermissionPrompt prompt)? onPrompt;

  /// Callable as a [PermissionAsker]: approves once, after a short async
  /// gap during which the test swaps the caller's live map.
  Future<PermissionResponse> ask(PermissionPrompt prompt) {
    seen.add('asked: ${prompt.input['command']}');
    onPrompt?.call(prompt);
    return Future<PermissionResponse>.delayed(
      const Duration(milliseconds: 5),
      () => PermissionResponse.allowOnce,
    );
  }
}
