/// Dedicated 429 retry loop (owner directive): a pre-publication rate
/// limit retries with backoff on its OWN per-turn budget — separate
/// from the one shared recovery (output_limit / stream_stalled) — with
/// the transport path's schedule shape (1s doubling to a 60s cap,
/// 50–100% jitter), server Retry-After precedence, per-retry notices,
/// gate cooldowns on every 429, and cancellation that wins over any
/// wait. Nothing here sleeps: the waits ride a recording fake and the
/// jitter is pinned.
library;

import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_providers/tina_providers.dart';

/// One entry per send call: a list of events to publish, or null for
/// the standard answer.
final class Scripted extends LlmProvider {
  Scripted(this.behavior) : super('scripted');
  final List<List<StreamEvent>?> behavior;
  int calls = 0;

  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) {
    final index = calls++;
    if (index >= behavior.length) return Stream.value(answer);
    final entry = behavior[index];
    if (entry == null) return Stream.value(answer);
    return Stream.fromIterable(entry);
  }

  @override
  void close() {}
}

const answer = MessageComplete(
    content: [TextBlock('answer')],
    stopReason: 'end_turn',
    usage: TokenUsage(inputTokens: 3, outputTokens: 2));

const rateLimited = StreamError('rate limited', statusCode: 429);

({
  ProviderPolicyPlugin policy,
  Scripted member,
  List<Duration> waits,
}) harness(
  Scripted member, {
  RequestLimits limits = const RequestLimits(),
  double jitter = 1.0,
  Future<bool> Function(Duration, Future<void>)? wait,
  List<ProviderTarget>? pool,
}) {
  final waits = <Duration>[];
  final policy = ProviderPolicyPlugin(
      targets: (_) =>
          pool ?? [ProviderTarget(id: 'a', create: () => member)],
      limits: limits,
      transportWait: wait ??
          (delay, aborted) async {
            waits.add(delay);
            return true;
          },
      transportJitter: () => jitter);
  return (policy: policy, member: member, waits: waits);
}

Future<List<StreamEvent>> run(LlmProvider provider) =>
    provider.send(system: '', messages: const [], tools: const []).toList();

void main() {
  test('the schedule doubles 1,2,4,8,16 then caps at 60', () async {
    // A budget large enough to reach the cap: 8 extra attempts.
    final member = Scripted(List.filled(9, [rateLimited]));
    final h = harness(member,
        limits: const RequestLimits(rateLimitRetries: 8));
    addTearDown(h.policy.closeSession);

    final events = await run(h.policy.mainProvider('x'));

    expect(h.member.calls, 9); // initial + 8 retries
    expect(h.waits, [
      const Duration(seconds: 1),
      const Duration(seconds: 2),
      const Duration(seconds: 4),
      const Duration(seconds: 8),
      const Duration(seconds: 16),
      const Duration(seconds: 32),
      const Duration(seconds: 60),
      const Duration(seconds: 60),
    ]);
    // Exhaustion is terminal and names the attempts and the total wait.
    final error = events.whereType<StreamError>().single;
    expect(error.error, contains('rate limited'));
    expect(error.error, contains('9 attempts'));
    expect(error.error, contains('3 minutes 3 s'));
  });

  test('the default budget is 5 extra attempts', () async {
    final member = Scripted(List.filled(20, [rateLimited]));
    final h = harness(member);
    addTearDown(h.policy.closeSession);

    final events = await run(h.policy.mainProvider('x'));

    expect(h.member.calls, rateLimitRetryLimit + 1);
    expect(h.waits, [
      const Duration(seconds: 1),
      const Duration(seconds: 2),
      const Duration(seconds: 4),
      const Duration(seconds: 8),
      const Duration(seconds: 16),
    ]);
    final error = events.whereType<StreamError>().single;
    expect(error.error, contains('6 attempts'));
    expect(error.error, contains('31s'));
  });

  test('jitter scales each wait to 50–100% of the base', () async {
    // Pin the jitter at its floor: every wait is exactly half the base.
    final member = Scripted(List.filled(5, [rateLimited]));
    final h = harness(member, jitter: 0.0);
    addTearDown(h.policy.closeSession);

    await run(h.policy.mainProvider('x'));

    expect(h.waits, [
      const Duration(milliseconds: 500),
      const Duration(seconds: 1),
      const Duration(seconds: 2),
      const Duration(seconds: 4),
      const Duration(seconds: 8),
    ]);
  });

  test('a server Retry-After hint takes precedence over the schedule',
      () async {
    // The gate cooldown runs on real time, so keep the hints short
    // enough for a unit test while still beating the schedule: 3s > 1s
    // on the first retry, 5s > 2s on the second.
    final member = Scripted([
      [
        const StreamError('rate limited',
            statusCode: 429, retryAfter: Duration(seconds: 3)),
      ],
      [
        const StreamError('rate limited',
            statusCode: 429, retryAfter: Duration(seconds: 5)),
      ],
      null,
    ]);
    final h = harness(member);
    addTearDown(h.policy.closeSession);

    final events = await run(h.policy.mainProvider('x'));

    // First wait: the 3s hint beats the 1s schedule. Second: the 5s
    // hint beats the 2s schedule. Jitter pinned at 1.0 = exact values.
    expect(h.waits, [
      const Duration(seconds: 3),
      const Duration(seconds: 5),
    ]);
    expect(events.last, answer);
    expect(h.member.calls, 3);
  }, timeout: const Timeout(Duration(seconds: 30)));

  test('a 429 never spends the shared recovery: output_limit still gets it',
      () async {
    // Attempt 1: 429 (own budget). Attempt 2: reasoning + output_limit
    // (shared recovery). Attempt 3: completes. The 429 must not have
    // consumed the one shared recovery.
    final member = Scripted([
      [rateLimited],
      [
        const ReasoningDelta('thinking'),
        const StreamError('output limit', providerCode: 'output_limit'),
      ],
      null,
    ]);
    final h = harness(member);
    addTearDown(h.policy.closeSession);

    final events = await run(h.policy.mainProvider('x'));

    expect(h.member.calls, 3);
    expect(events.last, answer);
    expect(events.whereType<StreamError>(), isEmpty);
    final notices = events.whereType<StreamNotice>().map((n) => n.text);
    expect(notices, contains(contains('rate limited - attempt 2/6')));
    expect(notices, contains(contains('Retrying once before any answer')));
    // The 429 waited on its own schedule; the output_limit recovery
    // added no wait.
    expect(h.waits, [const Duration(seconds: 1)]);
  });

  test('the reverse order also holds: output_limit then 429', () async {
    final member = Scripted([
      [
        const ReasoningDelta('thinking'),
        const StreamError('output limit', providerCode: 'output_limit'),
      ],
      [rateLimited],
      null,
    ]);
    final h = harness(member);
    addTearDown(h.policy.closeSession);

    final events = await run(h.policy.mainProvider('x'));

    expect(h.member.calls, 3);
    expect(events.last, answer);
    expect(events.whereType<StreamError>(), isEmpty);
    expect(h.waits, [const Duration(seconds: 1)]);
  });

  test('rate_limit_retries = 0: a 429 is terminal immediately', () async {
    final member = Scripted(List.filled(20, [rateLimited]));
    final h = harness(member,
        limits: const RequestLimits(rateLimitRetries: 0));
    addTearDown(h.policy.closeSession);

    final events = await run(h.policy.mainProvider('x'));

    expect(h.member.calls, 1);
    expect(h.waits, isEmpty);
    final error = events.whereType<StreamError>().single;
    expect(error.error, contains('rate limited'));
    expect(error.error, contains('1 attempts'));
    expect(error.error, contains('0s'));
    // No retry notices, and no shared-recovery consumption either: a
    // following output_limit in the same turn still recovers.
    expect(events.whereType<StreamNotice>(), isEmpty);
  });

  test('a disabled 429 leaves the shared recovery intact', () async {
    // With retries disabled the 429 is terminal for THAT request; a new
    // request in the same turn (the loop's next step) still gets the
    // shared recovery for an output_limit.
    final member = Scripted([
      [rateLimited],
      [
        const ReasoningDelta('thinking'),
        const StreamError('output limit', providerCode: 'output_limit'),
      ],
      null,
    ]);
    final h = harness(member,
        limits: const RequestLimits(rateLimitRetries: 0));
    addTearDown(h.policy.closeSession);

    final provider = h.policy.mainProvider('x');
    final first = await run(provider);
    expect(first.whereType<StreamError>().single.error,
        contains('rate limited'));
    // The policy's per-turn state persists across requests in the turn;
    // the shared recovery was never spent by the 429.
    final second = await run(provider);
    expect(second.last, answer);
    expect(h.member.calls, 3);
  });

  test('every retry emits a notice with its attempt counter', () async {
    final member = Scripted([
      [rateLimited],
      [rateLimited],
      [rateLimited],
      null,
    ]);
    final h = harness(member);
    addTearDown(h.policy.closeSession);

    final events = await run(h.policy.mainProvider('x'));

    final notices = events
        .whereType<StreamNotice>()
        .map((n) => n.text)
        .where((t) => t.startsWith('rate limited - attempt'))
        .toList();
    expect(notices, [
      'rate limited - attempt 2/6, next in ~1s',
      'rate limited - attempt 3/6, next in ~2s',
      'rate limited - attempt 4/6, next in ~4s',
    ]);
  });

  test('the gate cooldown still applies: a cooling member is skipped',
      () async {
    // Two members; the first 429s with a long Retry-After. The retry
    // rotates to the second member (pool rotation unchanged) while the
    // first sits in cooldown.
    final throttled = Scripted([
      [
        const StreamError('rate limited',
            statusCode: 429, retryAfter: Duration(seconds: 30)),
      ],
    ]);
    final healthy = Scripted([null]);
    final waits = <Duration>[];
    final policy = ProviderPolicyPlugin(
        targets: (_) => [
              ProviderTarget(id: 'throttled', create: () => throttled),
              ProviderTarget(id: 'healthy', create: () => healthy),
            ],
        transportWait: (delay, aborted) async {
          waits.add(delay);
          return true;
        },
        transportJitter: () => 1.0);
    addTearDown(policy.closeSession);

    final events = await run(policy.mainProvider('x'));

    expect(events.last, answer);
    expect(throttled.calls, 1);
    expect(healthy.calls, 1, reason: 'rotation reached the healthy member');
    expect(waits, [const Duration(seconds: 30)]);
    // A second request immediately after: the throttled member is still
    // cooling (30s), so the healthy member serves it without a wait.
    final before = DateTime.now();
    final second = await run(policy.mainProvider('x'));
    expect(second.last, answer);
    expect(DateTime.now().difference(before),
        lessThan(const Duration(seconds: 5)),
        reason: 'the cooling member was skipped, not waited out');
    expect(throttled.calls, 1);
    expect(healthy.calls, 2);
  });

  test('cancellation during a backoff wait aborts cleanly', () async {
    final member = Scripted(List.filled(20, [rateLimited]));
    var waitAborted = false;
    final policy = ProviderPolicyPlugin(
        targets: (_) => [ProviderTarget(id: 'a', create: () => member)],
        transportWait: (delay, aborted) async {
          waitAborted = true;
          return false; // the cancelled.future path fired
        },
        transportJitter: () => 1.0);
    addTearDown(policy.closeSession);

    final events = <StreamEvent>[];
    final done = Completer<void>();
    final subscription = policy
        .mainProvider('x')
        .send(system: '', messages: const [], tools: const [])
        .listen(events.add, onDone: done.complete);
    await done.future;
    await subscription.cancel();

    expect(waitAborted, isTrue);
    expect(member.calls, 1, reason: 'the loop stopped at the first failure');
    expect(events.whereType<StreamError>(), isEmpty);
    expect(events.whereType<MessageComplete>(), isEmpty);
  });

  test('a published (mid-stream) 429 stays terminal', () async {
    final member = Scripted([
      [const TextDelta('partial'), rateLimited],
    ]);
    final h = harness(member);
    addTearDown(h.policy.closeSession);

    final events = await run(h.policy.mainProvider('x'));

    expect(events.whereType<TextDelta>().single.text, 'partial');
    final error = events.whereType<StreamError>().single;
    expect(error.statusCode, 429);
    expect(h.member.calls, 1);
    expect(h.waits, isEmpty);
    expect(events.whereType<StreamNotice>().map((n) => n.text),
        isNot(contains(contains('rate limited - attempt'))));
  });

  test('a 429 requiring user action is terminal, no retry', () async {
    final member = Scripted([
      [
        const StreamError('quota exhausted',
            statusCode: 429, requiresUserAction: true),
      ],
    ]);
    final h = harness(member);
    addTearDown(h.policy.closeSession);

    final events = await run(h.policy.mainProvider('x'));

    final error = events.whereType<StreamError>().single;
    expect(error.error, contains('quota exhausted'));
    expect(h.member.calls, 1);
    expect(h.waits, isEmpty);
  });

  test('503 keeps the shared-recovery path, not the 429 loop', () async {
    final member = Scripted([
      [const StreamError('unavailable', statusCode: 503)],
      [const StreamError('unavailable', statusCode: 503)],
    ]);
    final h = harness(member);
    addTearDown(h.policy.closeSession);

    final events = await run(h.policy.mainProvider('x'));

    // Single member: the pool budget is one attempt, so the first 503
    // surfaces — no 429-style backoff notices or waits.
    expect(h.member.calls, 1);
    expect(h.waits, isEmpty);
    expect(events.whereType<StreamError>().single.statusCode, 503);
    expect(events.whereType<StreamNotice>().map((n) => n.text),
        isNot(contains(contains('rate limited - attempt'))));
  });

  test('the wall-clock cap surfaces before an over-budget wait', () async {
    // A huge Retry-After hint: the first wait would exceed the ~5 minute
    // cumulative envelope, so the loop surfaces instead of waiting.
    final member = Scripted([
      [
        const StreamError('rate limited',
            statusCode: 429, retryAfter: Duration(minutes: 10)),
      ],
    ]);
    final h = harness(member);
    addTearDown(h.policy.closeSession);

    final events = await run(h.policy.mainProvider('x'));

    expect(h.member.calls, 1);
    expect(h.waits, isEmpty, reason: 'the over-budget wait never started');
    final error = events.whereType<StreamError>().single;
    expect(error.error, contains('rate limited'));
    expect(error.error, contains('budget'));
  });

  test('the setting parses from the limits table and reaches the policy',
      () {
    final limits = RequestLimits.fromMap({'rate_limit_retries': 2});
    expect(limits.rateLimitRetries, 2);
    // Absent: the default budget.
    expect(RequestLimits.fromMap(const {}).rateLimitRetries,
        rateLimitRetryLimit);
    // Bad values reject like every other limit.
    expect(() => RequestLimits.fromMap({'rate_limit_retries': -1}),
        throwsFormatException);
    expect(() => RequestLimits.fromMap({'rate_limit_retries': 'many'}),
        throwsFormatException);
    // The setting definition is registered with the provider limits.
    final setting = providerLimitSettings
        .firstWhere((s) => s.id == 'tina/providers/rate_limit_retries');
    expect(setting.defaultValue, rateLimitRetryLimit);
    expect(setting.minimum, 0);
    expect(setting.configPath, ['limits', 'rate_limit_retries']);
  });

  test('updateLimits changes the budget live', () async {
    final member = Scripted(List.filled(20, [rateLimited]));
    final h = harness(member);
    addTearDown(h.policy.closeSession);

    // Lower the budget to 1 extra attempt between requests.
    h.policy.updateLimits(const RequestLimits(rateLimitRetries: 1));
    final events = await run(h.policy.mainProvider('x'));
    expect(h.member.calls, 2);
    expect(h.waits, [const Duration(seconds: 1)]);
    expect(events.whereType<StreamError>().single.error,
        contains('2 attempts'));
  });
}
