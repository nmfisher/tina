import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_providers/tina_providers.dart';

class Stub extends LlmProvider {
  Stub(this.reply) : super('stub');
  final Stream<StreamEvent> Function() reply;
  int calls = 0;
  bool closed = false;
  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) {
    calls++;
    return reply();
  }

  @override
  void close() {
    closed = true;
  }
}

const answer = MessageComplete(
    content: [TextBlock('answer')],
    stopReason: 'end_turn',
    usage: TokenUsage(inputTokens: 3, outputTokens: 2));
Stream<StreamEvent> request(LlmProvider p) =>
    p.send(system: '', messages: [], tools: []);
Future<void> tick() => Future<void>.delayed(const Duration(milliseconds: 15));
ProviderTarget target(String id, Stub p, {int concurrency = 4}) =>
    ProviderTarget(id: id, create: () => p, maxConcurrent: concurrency);

void main() {
  test('usage recording failure ends the request and releases its slot',
      () async {
    final stub = Stub(() => Stream.value(answer));
    final policy = ProviderPolicyPlugin(
        targets: (_) => [target('a', stub, concurrency: 1)]);
    addTearDown(policy.closeSession);
    final provider = policy.mainProvider('x');
    final loop = AgentLoop(provider: provider, plugins: [policy]);
    loop.mountPlugin(policy);
    final listener = loop.subscribe((entry, _) {
      if (entry is UsageRecordedEntry) throw StateError('store write failed');
    });
    final events =
        await request(provider).toList().timeout(const Duration(seconds: 1));
    expect(events.whereType<StreamError>().single.requiresUserAction, true);
    loop.unsubscribe(listener);
    expect(await request(provider).toList().timeout(const Duration(seconds: 1)),
        [answer]);
  });
  for (final (limits, child, reason) in [
    (const RequestLimits(globalTokens: 1), true, 'global'),
    (const RequestLimits(childTokens: 1), true, 'subagent'),
    (const RequestLimits(turnTokens: 1), false, 'turn'),
  ]) {
    test('estimated usage counts toward $reason ceiling', () async {
      final stub = Stub(() => Stream.value(const StreamError('failed')));
      final policy = ProviderPolicyPlugin(
          limits: limits, targets: (_) => [target('a', stub)]);
      addTearDown(policy.closeSession);
      final provider =
          child ? policy.childProvider('x') : policy.mainProvider('x');
      await request(provider).drain<void>();
      final error =
          (await request(provider).toList()).whereType<StreamError>().single;
      expect(error.error, contains(reason));
      expect(stub.calls, 1);
    });
  }
  test('unknown failed spend is estimated once and prevents budgeted failover',
      () async {
    final bad =
        Stub(() => Stream.value(const StreamError('outage', transient: true)));
    final good = Stub(() => Stream.value(answer));
    final policy = ProviderPolicyPlugin(
        limits: const RequestLimits(sessionTokens: 1),
        targets: (_) => [target('bad', bad), target('good', good)]);
    addTearDown(policy.closeSession);
    final events = await request(policy.mainProvider('x')).toList();
    expect(policy.sessionTokens, 0);
    expect(policy.sessionEstimatedTokens, greaterThan(0));
    expect(policy.globalEstimatedTokens, policy.sessionEstimatedTokens);
    expect(events.whereType<StreamError>().single.error,
        contains('session token'));
    expect(good.calls, 0);
  });
  test('reported failed usage wins over estimates, including zero usage',
      () async {
    for (final usage in [
      TokenUsage.zero,
      const TokenUsage(inputTokens: 7, outputTokens: 2)
    ]) {
      final bad = Stub(() =>
          Stream.value(StreamError('outage', transient: true, usage: usage)));
      final good = Stub(() => Stream.value(answer));
      final policy = ProviderPolicyPlugin(
          targets: (_) => [target('bad', bad), target('good', good)]);
      addTearDown(policy.closeSession);
      await request(policy.mainProvider('x')).drain<void>();
      expect(policy.sessionTokens, 5 + usage.inputTokens + usage.outputTokens);
      expect(policy.sessionEstimatedTokens, 0);
    }
  });
  test('abrupt EOF, synchronous throws and cancellation each book one estimate',
      () async {
    final source = StreamController<StreamEvent>();
    for (final reply in <Stream<StreamEvent> Function()>[
      () => const Stream.empty(),
      () => throw StateError('transport'),
      () => Stream.error(StateError('transport')),
      () => source.stream,
    ]) {
      final policy =
          ProviderPolicyPlugin(targets: (_) => [target('a', Stub(reply))]);
      addTearDown(policy.closeSession);
      final subscription = request(policy.mainProvider('x')).listen((_) {});
      await tick();
      await subscription.cancel();
      final estimate = policy.sessionEstimatedTokens;
      expect(estimate, greaterThan(0));
      await tick();
      expect(policy.sessionEstimatedTokens, estimate);
      expect(policy.sessionTokens, 0);
    }
    await source.close();
  });
  test('preflight refusal and queued cancellation spend nothing', () async {
    final source = StreamController<StreamEvent>();
    final stub = Stub(() => source.stream);
    final policy = ProviderPolicyPlugin(
        targets: (_) => [target('a', stub, concurrency: 1)]);
    addTearDown(policy.closeSession);
    final active = request(policy.mainProvider('x')).listen((_) {});
    await tick();
    final queued = request(policy.childProvider('x')).listen((_) {});
    await tick();
    await queued.cancel();
    expect(policy.globalEstimatedTokens, 0);
    await active.cancel();
    expect(policy.globalEstimatedTokens, policy.sessionEstimatedTokens);
    await source.close();
    final limited = ProviderPolicyPlugin(
        limits: const RequestLimits(requestTokens: 1),
        targets: (_) => [target('a', stub)]);
    addTearDown(limited.closeSession);
    await request(limited.mainProvider('x')).drain<void>();
    expect(limited.sessionEstimatedTokens, 0);
  });
  test(
      'journal resumes measured and estimated spend without double counting turn usage',
      () async {
    final bad =
        Stub(() => Stream.value(const StreamError('outage', transient: true)));
    final good = Stub(() => Stream.value(answer));
    final policy = ProviderPolicyPlugin(
        targets: (_) => [target('bad', bad), target('good', good)]);
    addTearDown(policy.closeSession);
    final loop =
        AgentLoop(provider: policy.mainProvider('x'), plugins: [policy]);
    loop.mountPlugin(policy);
    await loop.runTurn(const Input('one', id: '1'));
    await request(policy.childProvider('x')).drain<void>();
    expect(policy.sessionTokens, 5);
    expect(policy.sessionEstimatedTokens, greaterThan(0));
    final restored =
        ProviderPolicyPlugin(targets: (_) => [target('good', good)]);
    addTearDown(restored.closeSession);
    final seed = [
      const TurnEndedEntry(
          turnId: 'old',
          reason: TurnStopReason.complete,
          usage: EntryUsage(inputTokens: 11)),
      ...loop.log.map((e) => SessionEntry.fromJson(e.toJson())),
    ];
    final resumed = AgentLoop(
        provider: restored.mainProvider('x'),
        plugins: [restored],
        seedLog: seed);
    resumed.mountPlugin(restored);
    expect(restored.sessionTokens, policy.sessionTokens + 11);
    expect(restored.globalTokens, policy.globalTokens + 11);
    expect(restored.sessionEstimatedTokens, policy.sessionEstimatedTokens);
    expect(restored.globalEstimatedTokens, policy.globalEstimatedTokens);
    expect(resumed.derive().messages.map((m) => m.toJson()),
        loop.derive().messages.map((m) => m.toJson()));
  });
  test('pool rotates, fails over transient errors, and closes members',
      () async {
    final bad = Stub(
        () => Stream.value(const StreamError('unavailable', statusCode: 503)));
    final good = Stub(() => Stream.value(answer));
    final policy = ProviderPolicyPlugin(
        targets: (_) => [target('a', bad), target('b', good)]);
    final p = policy.mainProvider('x');
    expect(await request(p).toList(), contains(isA<MessageComplete>()));
    expect(bad.calls, 1);
    expect(good.calls, 1);
    expect(await request(p).toList(), [answer]);
    expect(bad.calls, 1);
    expect(good.calls, 2);
    policy.closeSession();
    expect(good.closed && bad.closed, true);
  });
  for (final first in [
    const TextDelta('partial'),
    const ToolCallStart(id: 'call', name: 'write'),
    const ReasoningDelta('thinking')
  ]) {
    test('never replays after ${first.runtimeType} has been published',
        () async {
      final bad = Stub(() => Stream.fromIterable(
          [first, const StreamError('failed', transient: true)]));
      final good = Stub(() => Stream.value(answer));
      final policy = ProviderPolicyPlugin(
          targets: (_) => [target('a', bad), target('b', good)]);
      addTearDown(policy.closeSession);
      final events = await request(policy.mainProvider('x')).toList();
      expect(events.first, first);
      expect(events.last, isA<StreamError>());
      expect(good.calls, 0);
    });
  }
  test('transport stream errors cancel upstream before failover', () async {
    var cancelled = false;
    final source = StreamController<StreamEvent>(onCancel: () {
      cancelled = true;
    });
    final bad = Stub(() => source.stream);
    final good = Stub(() => Stream.value(answer));
    final policy = ProviderPolicyPlugin(
        targets: (_) => [target('bad', bad), target('good', good)]);
    addTearDown(policy.closeSession);
    final result = request(policy.mainProvider('x')).toList();
    await tick();
    source.addError(StateError('transport ended'));
    expect(await result, contains(answer));
    expect(cancelled, true);
    await source.close();
  });
  test('main and children share slots; cancelled waiters never call upstream',
      () async {
    final stream = StreamController<StreamEvent>();
    final stub = Stub(() => stream.stream);
    final policy = ProviderPolicyPlugin(
        targets: (_) => [target('shared', stub, concurrency: 1)]);
    addTearDown(policy.closeSession);
    final active = request(policy.mainProvider('x')).listen((_) {});
    await tick();
    final queued = request(policy.childProvider('x')).listen((_) {});
    await tick();
    expect(stub.calls, 1);
    await queued.cancel();
    await active.cancel();
    await tick();
    expect(stub.calls, 1);
    await stream.close();
  });
  test('cancellation of active request promptly releases a shared slot',
      () async {
    final stream = StreamController<StreamEvent>();
    var count = 0;
    final stub =
        Stub(() => count++ == 0 ? stream.stream : Stream.value(answer));
    final policy = ProviderPolicyPlugin(
        targets: (_) => [target('shared', stub, concurrency: 1)]);
    addTearDown(policy.closeSession);
    final active = request(policy.mainProvider('x')).listen((_) {});
    await tick();
    final queued = request(policy.childProvider('x')).toList();
    await tick();
    expect(stub.calls, 1);
    await active.cancel();
    expect(await queued.timeout(const Duration(seconds: 1)), contains(answer));
    expect(stub.calls, 2);
    await stream.close();
  });
  test('session budget prevents subsequent upstream requests', () async {
    final stub = Stub(() => Stream.value(answer));
    final policy = ProviderPolicyPlugin(
        limits: const RequestLimits(sessionTokens: 5),
        targets: (_) => [target('a', stub)]);
    addTearDown(policy.closeSession);
    final p = policy.mainProvider('x');
    await request(p).drain<void>();
    final error = (await request(p).toList()).whereType<StreamError>().single;
    expect(error.error, contains('session token'));
    expect(stub.calls, 1);
  });
  test('child budgets are separate, global budget counts every child',
      () async {
    final stub = Stub(() => Stream.value(answer));
    final policy = ProviderPolicyPlugin(
        limits: const RequestLimits(childTokens: 5, globalTokens: 10),
        targets: (_) => [target('a', stub)]);
    addTearDown(policy.closeSession);
    final one = policy.childProvider('x');
    final two = policy.childProvider('x');
    await request(one).drain<void>();
    expect((await request(one).toList()).whereType<StreamError>().single.error,
        contains('subagent token'));
    expect(await request(two).toList(), [answer]);
    expect(
        (await request(policy.mainProvider('x')).toList())
            .whereType<StreamError>()
            .single
            .error,
        contains('global token'));
    expect(stub.calls, 2);
  });
  test('each new input resets the turn budget, resume restores session spend',
      () async {
    final stub = Stub(() => Stream.value(answer));
    final policy = ProviderPolicyPlugin(
        limits: const RequestLimits(turnTokens: 5),
        targets: (_) => [target('a', stub)]);
    addTearDown(policy.closeSession);
    final loop =
        AgentLoop(provider: policy.mainProvider('x'), plugins: [policy]);
    await loop.runTurn(const Input('one', id: '1'));
    await loop.runTurn(const Input('two', id: '2'));
    expect(stub.calls, 2);
    final restored = ProviderPolicyPlugin(
        limits: const RequestLimits(sessionTokens: 10),
        targets: (_) => [target('a', stub)]);
    addTearDown(restored.closeSession);
    final resumed = AgentLoop(
        provider: restored.mainProvider('x'),
        plugins: [restored],
        seedLog: loop.log);
    resumed.mountPlugin(restored);
    await resumed.runTurn(const Input('three', id: '3'));
    expect(stub.calls, 2);
  });
  test('oversized input is refused before opening a provider request',
      () async {
    final stub = Stub(() => Stream.value(answer));
    final policy = ProviderPolicyPlugin(
        limits: const RequestLimits(requestTokens: 1),
        targets: (_) => [target('a', stub)]);
    addTearDown(policy.closeSession);
    expect((await request(policy.mainProvider('x')).toList()).last,
        isA<StreamError>());
    expect(stub.calls, 0);
  });
  test('start spacing is respected and closing releases queued waiters',
      () async {
    final gate = LaunchGate(
        interval: const Duration(milliseconds: 45), maxConcurrent: 0);
    final cancel = Completer<void>();
    final first = await gate.acquire(cancel.future);
    first!();
    final watch = Stopwatch()..start();
    final second = await gate.acquire(cancel.future);
    expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(35));
    second!();
    final waiting = gate.acquire(cancel.future);
    gate.close();
    expect(await waiting, isNull);
    cancel.complete();
  });
}
