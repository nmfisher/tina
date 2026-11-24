/// Connection-phase transport backoff: a DNS/socket-level failure that
/// produced no response bytes keeps retrying the SAME member with
/// exponential backoff and jitter, instead of surfacing after one
/// recovery or burning the pool. HTTP-level failures (5xx) keep the
/// cooldown/pool behavior; 429 has its own dedicated loop (see
/// rate_limit_retry_test.dart) and never enters this one. Nothing here
/// sleeps: the waits ride a recording fake and the jitter is pinned.
library;

import 'dart:async';
import 'dart:io' show SocketException;

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_providers/tina_providers.dart';

class Flaky extends LlmProvider {
  Flaky(this.behavior) : super('flaky');

  /// One entry per send call: an Object to raise on the stream's
  /// error channel, an Iterable of events to publish, or null for the
  /// standard answer.
  final List<Object?> behavior;
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
    if (entry is List) {
      return Stream.fromIterable(entry.cast<StreamEvent>());
    }
    final controller = StreamController<StreamEvent>();
    scheduleMicrotask(() {
      controller.addError(entry);
      controller.close();
    });
    return controller.stream;
  }

  @override
  void close() {}
}

const answer = MessageComplete(
    content: [TextBlock('answer')],
    stopReason: 'end_turn',
    usage: TokenUsage(inputTokens: 3, outputTokens: 2));

const dnsDown = SocketException(
    "Failed host lookup: 'api.z.ai' (OS Error: nodename nor servname "
    'provided, or not known, errno = 8)');

({ProviderPolicyPlugin policy, Flaky member, List<Duration> waits})
harness(Flaky member,
    {Future<bool> Function(Duration, Future<void>)? wait}) {
  final waits = <Duration>[];
  final policy = ProviderPolicyPlugin(
      targets: (_) => [
            ProviderTarget(id: 'a', create: () => member, maxConcurrent: 4)
          ],
      transportWait:
          wait ?? (delay, aborted) async {
            waits.add(delay);
            return true;
          },
      // Pinned jitter: the wait is exactly the computed base.
      transportJitter: () => 1.0);
  return (policy: policy, member: member, waits: waits);
}

void main() {
  test('the classifier names connection-phase failures only', () {
    expect(isConnectionPhaseTransportFailure(dnsDown), isTrue);
    expect(
        isConnectionPhaseTransportFailure(
            SocketException('Connection refused')),
        isTrue);
    expect(isConnectionPhaseTransportFailure('HttpException: closed'), isTrue);
    expect(isConnectionPhaseTransportFailure(TimeoutException('t')),
        isTrue);
    // The HTTP/semantic layer and ordinary errors are not it.
    expect(
        isConnectionPhaseTransportFailure(
            const StreamError('rate limited', statusCode: 429)),
        isFalse);
    expect(isConnectionPhaseTransportFailure(StateError('boom')), isFalse);
    expect(isConnectionPhaseTransportFailure(ArgumentError('bad input')),
        isFalse);
  });

  test('a DNS outage retries with backoff until the network returns',
      () async {
    final h = harness(Flaky([dnsDown, dnsDown, dnsDown]));
    addTearDown(h.policy.closeSession);

    final events =
        await h.policy.mainProvider('x').send(system: '', messages: const [], tools: const []).toList();

    // The turn completed on the 4th call (3 failed + 1 success).
    expect(events.last, answer);
    expect(h.member.calls, 4);
    // The schedule: 1s, 2s, 4s — doubling, jittered, honored.
    expect(h.waits, [
      const Duration(seconds: 1),
      const Duration(seconds: 2),
      const Duration(seconds: 4),
    ]);
    // One notice per retry, each naming progress and the next delay.
    final notices = events.whereType<StreamNotice>().map((n) => n.text);
    expect(notices, contains('still no network — attempt 2/16 next in ~1s'));
    expect(notices, contains('still no network — attempt 3/16 next in ~2s'));
    expect(notices, contains('still no network — attempt 4/16 next in ~4s'));
  });

  test('the ceiling surfaces a clear error without burning the pool',
      () async {
    final member = Flaky(List.filled(100, dnsDown));
    final good = Flaky([null]);
    final waits = <Duration>[];
    final policy = ProviderPolicyPlugin(
        targets: (_) => [
              ProviderTarget(id: 'a', create: () => member, maxConcurrent: 4),
              ProviderTarget(id: 'b', create: () => good, maxConcurrent: 4),
            ],
        transportWait: (delay, aborted) async {
          waits.add(delay);
          return true;
        },
        transportJitter: () => 1.0);
    addTearDown(policy.closeSession);

    final events =
        await policy.mainProvider('x').send(system: '', messages: const [], tools: const []).toList();

    // Sixteen attempts on the SAME member (initial + 15 retries); the
    // healthy pool member was never contacted.
    expect(member.calls, transportRetryLimit + 1);
    expect(good.calls, 0);
    // The waits doubled to the cap: 1+2+4+8+16+32 then 60 nine times.
    expect(waits.length, transportRetryLimit);
    expect(waits.first, const Duration(seconds: 1));
    expect(waits[5], const Duration(seconds: 32));
    expect(waits[6], transportBackoffCap);
    expect(waits.last, transportBackoffCap);
    expect(waits.fold<int>(0, (total, d) => total + d.inSeconds), 603);
    // The surfaced error names the attempts, the total time and the
    // re-prompt.
    final error = events.whereType<StreamError>().single;
    expect(error.error, isNotEmpty);
    expect(error.error, contains('network unreachable'));
    expect(error.error, contains('16 attempts'));
    expect(error.error, contains('10 minutes'));
    expect(error.error, contains('re-prompt'));
    expect(error.error, contains('Failed host lookup'));
  });

  test('cancellation during the loop aborts immediately', () async {
    final member = Flaky(List.filled(100, dnsDown));
    var waitAborted = false;
    final policy = ProviderPolicyPlugin(
        targets: (_) => [
              ProviderTarget(id: 'a', create: () => member, maxConcurrent: 4)
            ],
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

  test('a mid-stream failure after publication surfaces, no restart',
      () async {
    final h = harness(Flaky([
      [const TextDelta('partial answer'), dnsDown as Object],
    ]));
    addTearDown(h.policy.closeSession);

    final events =
        await h.policy.mainProvider('x').send(system: '', messages: const [], tools: const []).toList();

    // Published content: today's rule — surface, never restart.
    expect(events.whereType<TextDelta>().single.text, 'partial answer');
    final error = events.whereType<StreamError>().single;
    expect(error.error, contains('provider transport failed'));
    expect(h.member.calls, 1);
    expect(h.waits, isEmpty);
    expect(events.whereType<StreamNotice>(), isEmpty);
  });

  test('429 keeps the cooldown gate, not the transport backoff loop',
      () async {
    final member = Flaky([
      [
        const StreamError('rate limited',
            statusCode: 429, retryAfter: Duration(seconds: 2)),
      ],
      null,
    ]);
    final h = harness(member);
    addTearDown(h.policy.closeSession);

    final events =
        await h.policy.mainProvider('x').send(system: '', messages: const [], tools: const []).toList();

    // The dedicated 429 loop (rate_limit_retry_test.dart) owns this
    // failure now: it retries on its own budget with its own notices.
    // What must NOT happen is the transport path — no 'still no
    // network' notices, and the cooldown gate still applies.
    expect(events.whereType<StreamNotice>().map((n) => n.text),
        isNot(contains(contains('still no network'))));
    expect(events.whereType<StreamNotice>().map((n) => n.text),
        contains(contains('rate limited - attempt')));
    expect(events.last, answer);
    expect(member.calls, 2);
    // The retryAfter hint (2s) rode the 429 backoff, not a 1s schedule.
    expect(h.waits, [const Duration(seconds: 2)]);
  }, timeout: const Timeout(Duration(seconds: 30)));
}
