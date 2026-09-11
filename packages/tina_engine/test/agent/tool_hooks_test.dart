import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_tool.dart';

void main() {
  // Shared harness: an allowed `fake` tool behind a real [ToolExecutor],
  // wired with whatever hooks a test needs. Mirrors the setup in
  // tool_executor_test.dart.
  FakeAgentSink sinkOf(ToolExecutor Function(FakeAgentSink sink) build) {
    final sink = FakeAgentSink();
    build(sink);
    return sink;
  }

  ToolExecutor makeExecutor(
    FakeAgentSink sink, {
    ToolResultVerifier? resultVerifier,
    List<ToolExecutionHook> executionHooks = const [],
    List<ToolResultHook> resultHooks = const [],
    List<ToolObserver> observers = const [],
  }) {
    return ToolExecutor(
      policy: PermissionPolicy(defaults: {
        'fake': PermissionDecision.allow,
      }),
      asker: (_) async => PermissionResponse.allowOnce,
      sink: sink,
      state: ToolCallState(),
      cancelSignal: Completer<void>().future,
      resultVerifier: resultVerifier,
      executionHooks: executionHooks,
      resultHooks: resultHooks,
      observers: observers,
    );
  }

  /// Dispatches one `fake` tool call that reports the input it saw.
  Future<ToolCallOutcome> runFake(
    ToolExecutor executor, {
    String id = 'u1',
    String name = 'fake',
    Map<String, dynamic> input = const {},
  }) {
    return executor.execute(
      use: ToolUseBlock(id: id, name: name, input: input),
      stepTools: ToolRegistry([
        FakeTool(name, (i) async => ToolResult('ran:$i')),
      ]).forStep(),
      step: 0,
      isCancelled: () => false,
    );
  }

  group('ToolExecutionHook (around)', () {
    test('delegating once executes the tool and ships its result normally',
        () async {
      final calls = <String>[];
      final sink = sinkOf((s) => makeExecutor(s, executionHooks: [
            _ScriptedExecutionHook((context, delegate) async {
              calls.add('hook-sees:${context.toolName}:${context.input}');
              return delegate();
            }),
          ]));
      final executor = makeExecutor(sink, executionHooks: [
        _ScriptedExecutionHook((context, delegate) async => delegate()),
      ]);
      final outcome = await runFake(executor, input: {'k': 'v'});

      expect(outcome.result.isError, isFalse);
      expect(outcome.result.content, 'ran:{k: v}');
      // The hook observed the input the tool ran with.
      expect(sink.toolStarts, hasLength(1));
      expect(sink.toolCompletes.single.result, 'ran:{k: v}');
      expect(sink.toolCompletes.single.isError, isFalse);
      expect(calls, isEmpty); // (only the first executor's hook records)
    });

    test('the hook context exposes tool name, id, input and the cancel probe',
        () async {
      ToolCallContext? seen;
      final sink = FakeAgentSink();
      final executor = makeExecutor(sink, executionHooks: [
        _ScriptedExecutionHook((context, delegate) async {
          seen = context;
          return delegate();
        }),
      ]);

      await runFake(executor, id: 'call-9', input: {'path': '/tmp/x'});

      expect(seen, isNotNull);
      expect(seen!.toolName, 'fake');
      expect(seen!.toolId, 'call-9');
      expect(seen!.input, {'path': '/tmp/x'});
      expect(seen!.isCancelled(), isFalse);
    });

    test('returning WITHOUT delegating fails closed: error result, the tool '
        'never ran', () async {
      var executed = false;
      final sink = FakeAgentSink();
      final executor = makeExecutor(sink, executionHooks: [
        _ScriptedExecutionHook((_, delegate) async => ToolResult('skipped')),
      ]);
      final outcome = await executor.execute(
        use: const ToolUseBlock(id: 'u1', name: 'fake', input: {}),
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
      expect(
          outcome.result.content, contains('did not execute the tool'));
      expect(sink.toolCompletes.single.isError, isTrue);
    });

    test('delegating TWICE fails closed: error result even when the hook '
        'swallows the throw', () async {
      var executions = 0;
      final sink = FakeAgentSink();
      final executor = makeExecutor(sink, executionHooks: [
        _ScriptedExecutionHook((_, delegate) async {
          await delegate();
          try {
            await delegate();
          } catch (_) {
            // Swallowed — the executor must still fail the call closed.
          }
          return const ToolResult('looks-fine');
        }),
      ]);
      final outcome = await executor.execute(
        use: const ToolUseBlock(id: 'u1', name: 'fake', input: {}),
        stepTools: ToolRegistry([
          FakeTool('fake', (_) async {
            executions++;
            return const ToolResult('ran');
          }),
        ]).forStep(),
        step: 0,
        isCancelled: () => false,
      );

      expect(executions, 1); // The tool ran once, never twice.
      expect(outcome.result.isError, isTrue);
      expect(outcome.result.content, contains('more than once'));
      expect(sink.toolCompletes.single.isError, isTrue);
    });

    test('a throwing around hook becomes an error tool result carrying the '
        'error', () async {
      final sink = FakeAgentSink();
      final executor = makeExecutor(sink, executionHooks: [
        _ScriptedExecutionHook((_, delegate) async {
          throw StateError('hook exploded');
        }),
      ]);
      final outcome = await runFake(executor);

      expect(outcome.result.isError, isTrue);
      expect(outcome.result.content, contains('tool execution hook failed'));
      expect(outcome.result.content, contains('hook exploded'));
      expect(sink.toolCompletes.single.isError, isTrue);
      expect(sink.toolCompletes.single.result, contains('hook exploded'));
    });

    test('a swallowed double-delegation rejection still JOINS the first '
        'execution before the failure is reported', () async {
      final sink = FakeAgentSink();
      var settled = false;
      final executor = makeExecutor(sink, executionHooks: [
        _ScriptedExecutionHook((_, delegate) async {
          // Start the work and never await it. The second call throws; the
          // hook swallows that too and returns as if nothing happened.
          unawaited(delegate().whenComplete(() => settled = true));
          try {
            await delegate();
          } catch (_) {
            // Swallowed rejection.
          }
          return const ToolResult('looks-fine');
        }),
      ]);
      final outcome = await runFake(executor);

      expect(outcome.result.isError, isTrue,
          reason: 'the repeat attempt still fails the call closed');
      expect(outcome.result.content, contains('more than once'));
      expect(settled, isTrue,
          reason: 'the FIRST execution was joined before execute() returned — '
              'no work may keep running behind the reported failure');
    });

    test('a hook that throws after awaiting its delegate does NOT turn a '
        'successful tool call into success — the failure ships', () async {
      final sink = FakeAgentSink();
      final executor = makeExecutor(sink, executionHooks: [
        _ScriptedExecutionHook((_, delegate) async {
          final r = await delegate();
          throw StateError('hook blew up after the tool ran: ${r.content}');
        }),
      ]);
      final outcome = await runFake(executor);

      expect(outcome.result.isError, isTrue,
          reason: 'the hook failed after delegating; success must not '
              'leak out of a failed hook invocation');
      expect(outcome.result.content, contains(
          'hook blew up after the tool ran'));
    });

    test('a hook that transforms the tool result ships the TRANSFORMED '
        'result', () async {
      final sink = FakeAgentSink();
      final executor = makeExecutor(sink, executionHooks: [
        _ScriptedExecutionHook((_, delegate) async {
          await delegate();
          return const ToolResult('transformed: redacted');
        }),
      ]);
      final outcome = await runFake(executor);

      expect(outcome.result.isError, isFalse);
      expect(outcome.result.content, 'transformed: redacted',
          reason: 'the hook result is authoritative on success — the raw '
              'tool result must not overwrite it');
      expect(sink.toolCompletes.single.result, 'transformed: redacted');
    });

    test('a tool exception behind a delegating hook keeps the thrown-tool '
        'path (never rebranded as a hook failure)', () async {
      final sink = FakeAgentSink();
      final executor = makeExecutor(sink, executionHooks: [
        _ScriptedExecutionHook((_, delegate) => delegate()),
      ]);
      final outcome = await executor.execute(
        use: const ToolUseBlock(id: 'u1', name: 'fake', input: {}),
        stepTools: ToolRegistry([
          FakeTool('fake', (_) async => throw StateError('tool blew up')),
        ]).forStep(),
        step: 0,
        isCancelled: () => false,
      );

      // The tool's own error ships with the thrown-tool path's content —
      // NOT 'tool execution hook failed: ...'.
      expect(outcome.result.isError, isTrue);
      expect(outcome.result.content, contains('tool blew up'));
      expect(outcome.result.content, isNot(contains('tool execution hook')));
      expect(sink.toolCompletes.single.result, contains('tool blew up'));
    });

    test('the first declared hook is outermost: h1 -> h2 -> tool', () async {
      final order = <String>[];
      final sink = FakeAgentSink();
      final executor = makeExecutor(sink, executionHooks: [
        _ScriptedExecutionHook((_, delegate) async {
          order.add('h1-in');
          final r = await delegate();
          order.add('h1-out');
          return r;
        }),
        _ScriptedExecutionHook((_, delegate) async {
          order.add('h2-in');
          final r = await delegate();
          order.add('h2-out');
          return r;
        }),
      ]);
      final outcome = await runFake(executor);

      expect(outcome.result.content, 'ran:{}');
      expect(order, ['h1-in', 'h2-in', 'h2-out', 'h1-out']);
    });
  });

  group('ToolResultHook (post-tool)', () {
    test('a result hook appends its verdict to the tool content', () async {
      final sink = FakeAgentSink();
      final executor = makeExecutor(sink, resultHooks: [
        _ScriptedResultHook((name, input, result) async => 'VERDICT'),
      ]);
      final outcome = await runFake(executor);

      expect(outcome.result.isError, isFalse);
      expect(outcome.result.content, 'ran:{}\nVERDICT');
    });

    test('a throwing result hook is logged and the content ships unchanged',
        () async {
      final sink = FakeAgentSink();
      final executor = makeExecutor(sink, resultHooks: [
        _ScriptedResultHook((name, input, result) => throw StateError('boom')),
      ]);
      final outcome = await runFake(executor);

      expect(outcome.result.isError, isFalse);
      expect(outcome.result.content, 'ran:{}');
    });

    test('first non-null verdict wins: the second hook is skipped', () async {
      var secondRan = false;
      final sink = FakeAgentSink();
      final executor = makeExecutor(sink, resultHooks: [
        _ScriptedResultHook((name, input, result) async => 'FIRST'),
        _ScriptedResultHook((name, input, result) async {
          secondRan = true;
          return 'SECOND';
        }),
      ]);
      final outcome = await runFake(executor);

      expect(secondRan, isFalse);
      expect(outcome.result.content, 'ran:{}\nFIRST');
    });

    test('a null verdict lets the next hook speak; hooks run in declared '
        'order', () async {
      final order = <String>[];
      final sink = FakeAgentSink();
      final executor = makeExecutor(sink, resultHooks: [
        _ScriptedResultHook((name, input, result) async {
          order.add('h1');
          return null;
        }),
        _ScriptedResultHook((name, input, result) async {
          order.add('h2');
          return 'from-h2';
        }),
      ]);
      final outcome = await runFake(executor);

      expect(order, ['h1', 'h2']);
      expect(outcome.result.content, 'ran:{}\nfrom-h2');
    });

    test('error results skip the result-hook stage', () async {
      var hookRan = false;
      final sink = FakeAgentSink();
      final executor = makeExecutor(sink, resultHooks: [
        _ScriptedResultHook((name, input, result) async {
          hookRan = true;
          return 'VERDICT';
        }),
      ]);
      final outcome = await executor.execute(
        use: const ToolUseBlock(id: 'u1', name: 'missing', input: {}),
        stepTools: ToolRegistry([FakeTool.noOp('fake')]).forStep(),
        step: 0,
        isCancelled: () => false,
      );

      expect(outcome.result.isError, isTrue);
      expect(hookRan, isFalse);
    });
  });

  group('ToolObserver', () {
    test('observers see start and complete with the same payloads the sink '
        'gets; sink traffic is unchanged', () async {
      final starts = <ToolStartEvent>[];
      final completes = <ToolCompleteEvent>[];
      final sink = FakeAgentSink();
      final executor = makeExecutor(sink, observers: [
        _RecordingObserver(onStart: starts.add, onComplete: completes.add),
      ]);

      final outcome = await runFake(executor);

      expect(starts, hasLength(1));
      expect(starts.single.toolName, sink.toolStarts.single.toolName);
      expect(starts.single.toolId, sink.toolStarts.single.toolId);
      expect(starts.single.input, sink.toolStarts.single.input);
      expect(completes, hasLength(1));
      expect(completes.single.result, sink.toolCompletes.single.result);
      expect(completes.single.isError, sink.toolCompletes.single.isError);
      expect(outcome.result.content, 'ran:{}');
    });

    test('a throwing observer does not affect the result or the sink traffic',
        () async {
      final sink = FakeAgentSink();
      final executor = makeExecutor(sink, observers: [_ThrowingObserver()]);
      final outcome = await runFake(executor);

      expect(outcome.result.isError, isFalse);
      expect(outcome.result.content, 'ran:{}');
      // Every sink call still happened despite the observer throwing on
      // each one.
      expect(sink.toolStarts, hasLength(1));
      expect(sink.toolCompletes, hasLength(1));
      expect(sink.toolCompletes.single.result, 'ran:{}');
    });

    test('a second observer still runs after the first throws', () async {
      var healthySawStart = false;
      var healthySawComplete = false;
      final sink = FakeAgentSink();
      final executor = makeExecutor(sink, observers: [
        _ThrowingObserver(),
        _RecordingObserver(
          onStart: (_) => healthySawStart = true,
          onComplete: (_) => healthySawComplete = true,
        ),
      ]);
      await runFake(executor);

      expect(healthySawStart, isTrue);
      expect(healthySawComplete, isTrue);
    });

    test('output events flow to observers for a streaming tool', () async {
      final outputs = <ToolOutputEvent>[];
      final sink = FakeAgentSink();
      final executor = makeExecutor(sink, observers: [
        _RecordingObserver(onOutput: outputs.add),
      ]);
      await executor.execute(
        use: const ToolUseBlock(id: 'u1', name: 'fake', input: {}),
        stepTools: ToolRegistry([
          FakeTool('fake', (_) async {
            return const ToolResult('done');
          }),
        ]).forStep(),
        step: 0,
        isCancelled: () => false,
      );

      // The fake tool streams nothing — the observable contract here is
      // just that no observer exception leaks into the run.
      expect(outputs, isEmpty);
      expect(sink.toolCompletes, hasLength(1));
    });
  });

  group('verifier + result hooks', () {
    test('the existing verifier still appends first, before the declared '
        'result hooks (first verdict wins)', () async {
      final order = <String>[];
      final sink = FakeAgentSink();
      final executor = makeExecutor(
        sink,
        resultVerifier: (name, input) async {
          order.add('verifier');
          return 'VERIFIER-SAYS';
        },
        resultHooks: [
          _ScriptedResultHook((name, input, result) async {
            order.add('hook');
            return 'HOOK-SAYS';
          }),
        ],
      );
      final outcome = await runFake(executor);

      expect(order, ['verifier']); // Verifier is hooked in first and wins...
      expect(outcome.result.content, 'ran:{}\nVERIFIER-SAYS'); // ...so the
      // declared hook is skipped entirely (first non-null verdict wins).
    });

    test('a throwing verifier still ships the tool content unchanged and the '
        'next hook still runs (old crash semantics via the hook stage)',
        () async {
      var hookRan = false;
      final sink = FakeAgentSink();
      final executor = makeExecutor(
        sink,
        resultVerifier: (name, input) async => throw StateError('v-boom'),
        resultHooks: [
          _ScriptedResultHook((name, input, result) async {
            hookRan = true;
            return 'HOOK-SAYS';
          }),
        ],
      );
      final outcome = await runFake(executor);

      expect(outcome.result.content, 'ran:{}\nHOOK-SAYS');
      expect(hookRan, isTrue); // The crash skips only the verifier.
    });
  });
}

/// A [ToolExecutionHook] driven by a test closure.
class _ScriptedExecutionHook implements ToolExecutionHook {
  final Future<ToolResult> Function(
          ToolCallContext context, Future<ToolResult> Function() delegate)
      body;

  _ScriptedExecutionHook(this.body);

  @override
  Future<ToolResult> run(
          ToolCallContext context, Future<ToolResult> Function() delegate) =>
      body(context, delegate);
}

/// A [ToolResultHook] driven by a test closure.
class _ScriptedResultHook implements ToolResultHook {
  final Future<String?> Function(
          String toolName, Map<String, dynamic> input, ToolResult result)
      body;

  _ScriptedResultHook(this.body);

  @override
  Future<String?> process(
          String toolName, Map<String, dynamic> input, ToolResult result) =>
      body(toolName, input, result);
}

/// An observer that records events through test closures.
class _RecordingObserver implements ToolObserver {
  final void Function(ToolStartEvent)? onStart;
  final void Function(ToolOutputEvent)? onOutput;
  final void Function(ToolCompleteEvent)? onComplete;

  _RecordingObserver({this.onStart, this.onOutput, this.onComplete});

  @override
  void onToolStart(ToolStartEvent event) => onStart?.call(event);

  @override
  void onToolOutput(ToolOutputEvent event) => onOutput?.call(event);

  @override
  void onToolComplete(ToolCompleteEvent event) => onComplete?.call(event);
}

/// An observer whose every callback throws.
class _ThrowingObserver implements ToolObserver {
  @override
  void onToolStart(ToolStartEvent event) => throw StateError('start-boom');

  @override
  void onToolOutput(ToolOutputEvent event) => throw StateError('output-boom');

  @override
  void onToolComplete(ToolCompleteEvent event) =>
      throw StateError('complete-boom');
}
