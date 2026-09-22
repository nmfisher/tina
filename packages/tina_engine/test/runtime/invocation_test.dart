import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_agent_sink.dart';
import '../helpers/fake_tool.dart';
import '../helpers/fake_provider.dart';

void main() {
  test('a hold during retry backoff blocks the next model request', () async {
    final call = Invocations().create(
        component: const ComponentInfo('a', 'Agent'), conversationId: 'c');
    final inner = FakeProvider([
      [const StreamError('retry', transient: true, retryAfter: Duration.zero)],
      [
        const MessageComplete(
            content: [TextBlock('done')], stopReason: 'end_turn')
      ],
    ]);
    final provider = RetryingProvider(MeteringProvider(
        inner, SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0)));
    final held = Completer<Registration>();
    final running = call.run((_) async {
      await for (final event
          in provider.send(system: '', messages: [], tools: [])) {
        if (event is StreamNotice && !held.isCompleted)
          held.complete(call.hold());
      }
    });
    final hold = await held.future;
    await pumpEventQueue();
    expect(inner.calls, hasLength(1));
    await hold.dispose();
    await running;
    expect(inner.calls, hasLength(2));
  });

  test('parent and child output preserve their shared order while held',
      () async {
    final calls = Invocations();
    final parent = calls.create(
        component: const ComponentInfo('a', 'Agent'), conversationId: 'c');
    final child = calls.create(
        component: const ComponentInfo('b', 'Child'),
        conversationId: 'c',
        parent: parent);
    final hold = parent.hold();
    final output = <int>[];
    child.output(() => output.add(1));
    parent.output(() => output.add(2));
    child.output(() => output.add(3));
    await hold.dispose();
    expect(output, [1, 2, 3]);
    await calls.dispose();
  });

  test(
      'accepting a hold retains real tool results and skips the remaining tools',
      () async {
    final calls = Invocations();
    final call = calls.create(
        component: const ComponentInfo('a', 'Agent'), conversationId: 'c');
    final began = Completer<void>();
    final finishTool = Completer<void>();
    var secondRan = false;
    final provider = FakeProvider([
      [
        const MessageComplete(content: [
          ToolUseBlock(id: 'one', name: 'one', input: {}),
          ToolUseBlock(id: 'two', name: 'two', input: {}),
        ], stopReason: 'tool_use')
      ],
    ]);
    final history = <Message>[];
    final saved = <Message>[];
    final agent = Agent(
        provider: provider,
        tools: ToolRegistry([
          FakeTool('one', (_) async {
            began.complete();
            await finishTool.future;
            return const ToolResult('file changed');
          }),
          FakeTool('two', (_) async {
            secondRan = true;
            return const ToolResult('wrong');
          }),
        ]),
        sink: FakeAgentSink(),
        policy: PermissionPolicy(defaults: {
          'one': PermissionDecision.allow,
          'two': PermissionDecision.allow,
        }),
        asker: (_) async => PermissionResponse.denyOnce,
        system: '',
        onHistoryAppend: (message) async => saved.add(message));
    final running =
        call.run((_) => agent.run(history: history, userInput: 'change files'));
    final stopped = expectLater(running, throwsA(isA<InvocationCancelled>()));
    await began.future;
    final hold = call.hold();
    call.cancel('accepted');
    expect(call.isDone, isFalse, reason: 'the actual tool is still running');
    finishTool.complete();
    await stopped;
    await hold.dispose();
    final results =
        saved.expand((m) => m.content).whereType<ToolResultBlock>().toList();
    expect(results.map((r) => r.toolUseId), ['one', 'two']);
    expect(results.first.content, 'file changed');
    expect(results.last.isError, isTrue);
    expect(secondRan, isFalse);
    expect(provider.calls, hasLength(1));
  });

  test(
      'metered requests cannot start while held and cancel without a wire call',
      () async {
    final call = Invocations().create(
        component: const ComponentInfo('a', 'Agent'), conversationId: 'c');
    final inner = FakeProvider(const []);
    final provider = MeteringProvider(
        inner, SpendLedger(maxGlobalTokens: 0, requestsPerMinute: 0));
    final held = Completer<Registration>();
    final running = call.run((_) async {
      held.complete(call.hold());
      return provider.send(system: '', messages: [], tools: []).toList();
    });
    final stopped = expectLater(running, throwsA(isA<InvocationCancelled>()));
    final hold = await held.future;
    await pumpEventQueue();
    expect(inner.calls, isEmpty);
    call.cancel();
    await stopped;
    await hold.dispose();
    expect(inner.calls, isEmpty);
  });

  test('independent holds preserve output order and gate completion', () async {
    final calls = Invocations();
    final call = calls.create(
        component: const ComponentInfo('agent', 'Agent'), conversationId: 'c');
    final entered = Completer<void>();
    final finish = Completer<void>();
    final output = <String>[];
    final running = call.run((context) async {
      expect(InvocationContext.current, same(context));
      entered.complete();
      await finish.future;
      return 42;
    });
    await entered.future;
    final first = call.hold();
    final second = call.hold();
    call.output(() => output.add('one'));
    call.output(() => output.add('two'));
    finish.complete();
    await first.dispose();
    expect(call.isDone, isFalse);
    expect(output, isEmpty);
    await second.dispose();
    expect(await running, 42);
    expect(output, ['one', 'two']);
    expect(calls.active, isEmpty);
  });

  test('parent holds and cancellation include children but leave peers alone',
      () async {
    final calls = Invocations();
    final parent = calls.create(
        component: const ComponentInfo('a', 'Agent'), conversationId: 'c');
    final peer = calls.create(
        component: const ComponentInfo('b', 'Classifier'), conversationId: 'c');
    final child = calls.create(
        component: const ComponentInfo('child', 'Child'),
        conversationId: 'c',
        parent: parent);
    final hold = parent.hold();
    expect(child.isHeld, isTrue);
    expect(peer.isHeld, isFalse);
    final output = <String>[];
    child.output(() => output.add('hidden'));
    parent.cancel('handoff');
    await hold.dispose();
    child.output(() => output.add('late'));
    expect(output, isEmpty);
    expect(child.cancelReason, 'handoff');
    expect(peer.isCancelled, isFalse);
    peer.cancel();
  });

  test('provider subscription pauses and cancellation releases a held stream',
      () async {
    final calls = Invocations();
    final call = calls.create(
        component: const ComponentInfo('a', 'Agent'), conversationId: 'c');
    final started = Completer<void>();
    var paused = false;
    final stream = StreamController<StreamEvent>(
        onListen: () => started.complete(),
        onPause: () => paused = true,
        onResume: () => paused = false);
    final sink = FakeAgentSink();
    final running = call.run((_) => const ProviderStreamConsumer()
        .consume(stream.stream, sink: InvocationSink(sink, call)));
    final stopped = expectLater(running, throwsA(isA<InvocationCancelled>()));
    await started.future;
    final hold = call.hold();
    expect(paused, isTrue);
    stream.add(const TextDelta('unseen'));
    call.cancel('accepted');
    await stopped;
    await hold.dispose();
    await stream.close();
    expect(sink.texts, isEmpty);
    expect(call.state, InvocationState.cancelled);
  });

  test('hold after permission answer prevents actual dispatch', () async {
    final call = Invocations().create(
        component: const ComponentInfo('a', 'Agent'), conversationId: 'c');
    final asked = Completer<void>();
    final answer = Completer<PermissionResponse>();
    var executions = 0;
    final sink = FakeAgentSink();
    final running = call.run((context) async {
      final executor = ToolExecutor(
          policy: PermissionPolicy(defaults: {'fake': PermissionDecision.ask}),
          asker: (_) {
            asked.complete();
            return answer.future;
          },
          sink: InvocationSink(sink, call),
          state: ToolCallState());
      return executor.execute(
          use: const ToolUseBlock(id: 't', name: 'fake', input: {}),
          stepTools: ToolRegistry([
            FakeTool('fake', (_) async {
              executions++;
              return const ToolResult('ran');
            })
          ]).forStep(),
          step: 0,
          isCancelled: () => context.isCancelled);
    });
    final stopped = expectLater(running, throwsA(isA<InvocationCancelled>()));
    await asked.future;
    final hold = call.hold();
    answer.complete(PermissionResponse.allowOnce);
    await pumpEventQueue();
    expect(executions, 0);
    call.cancel('accepted');
    await stopped;
    await hold.dispose();
    expect(executions, 0);
  });

  test('buffer overflow cancels instead of silently resuming lost output', () {
    final call = Invocations(maxBufferedSize: 4).create(
        component: const ComponentInfo('a', 'Agent'), conversationId: 'c');
    call.hold();
    call.output(() {}, size: 5);
    expect(call.isCancelled, isTrue);
    expect(call.bufferedSize, 0);
  });
}
