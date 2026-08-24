import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

/// #45: the transport retry ladder is agent-event-silent by design, so a run
/// grinding through a bad provider patch was indistinguishable from a wedged
/// one to the headless watchdog. The [Wire] feed lets every layer report its
/// transitions, the ladder arithmetic names the worst case a send may
/// legitimately climb, and [reconcileWatchdogWithLadder] keeps the watchdog
/// above it.
class _SilentFlaky implements LlmProvider {
  @override
  String model = 'm';
  @override
  void close() {}
  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    // Reports NOTHING itself — the ladder around it must be the reporter.
    yield const StreamError('boom', statusCode: 500, transient: true);
  }
}

void main() {
  tearDown(() => Wire.onWireEvent = null);

  test('the REAL ladder reports attempts and backoff (fake stays silent)',
      () async {
    final events = <String>[];
    Wire.onWireEvent = (s) => events.add(s.event);
    final p = RetryingProvider(_SilentFlaky(), maxRetries: 1);
    await p.send(system: 's', messages: [], tools: []).drain();
    // The retry ladder reported its own rungs — not the fake.
    expect(events, containsAll(['attempt_start', 'backoff', 'attempt_end']));
    // Two attempts (initial + one retry): the rungs are numbered.
    expect(events.where((e) => e == 'attempt_start'), hasLength(2));
    expect(Wire.last, isNotNull);
    expect(Wire.last!.inFlight, isFalse,
        reason: 'the wire is idle once the send drains');
  });

  test('a pooled send reports member rotation through the layered stack',
      () async {
    final events = <String>[];
    Wire.onWireEvent = (s) => events.add(s.event);
    // Pool wrapping retry wrapping the silent fake: every layer reports
    // through the same seam despite the layering.
    final p = PooledProvider(
        [RetryingProvider(_SilentFlaky(), maxRetries: 1)],
        cooldown: Duration.zero);
    await p.send(system: 's', messages: [], tools: []).drain();
    expect(events, containsAll(['pool_rotate', 'attempt_start']));
    expect(events.first, 'pool_rotate',
        reason: 'the pool names its member before the retry ladder runs');
  });

  test('a null hook makes reporting free (no throw, no state leak)', () async {
    final p = RetryingProvider(_SilentFlaky(), maxRetries: 0);
    await p.send(system: 's', messages: [], tools: []).drain();
    expect(Wire.last, isNotNull, reason: 'state is kept even without a hook');
  });

  test('worst-case ladder arithmetic uses real constants', () {
    final wc = wireLadderWorstCase(bodyBytes: 200 * 1024, members: 3);
    // scaledRequestTimeout(200KB) = 30 + 50 = 80s per attempt — the floor
    // must at least cover ONE attempt.
    expect(wc.inSeconds, greaterThanOrEqualTo(80));
    // And it legitimately exceeds the 300s default watchdog once the pool
    // rotates and each retry honors a Retry-After park:
    // 4 × (3×80 + 5) + 3×60 = 1160s.
    expect(wc.inSeconds, greaterThan(300));
  });

  test('reconcile clamps a too-small watchdog to the computed floor', () {
    final r = reconcileWatchdogWithLadder(
        watchdogSeconds: 300, bodyBytes: 200 * 1024, members: 3);
    expect(r.raised, isTrue);
    expect(r.seconds,
        wireLadderWorstCase(bodyBytes: 200 * 1024, members: 3).inSeconds);
    // Already-big enough: untouched, no warning.
    final ok = reconcileWatchdogWithLadder(
        watchdogSeconds: 100000, bodyBytes: 200 * 1024, members: 3);
    expect(ok.raised, isFalse);
    expect(ok.seconds, 100000);
  });

  test('the MINIMUM ladder (1 member, empty body) still exceeds the 300s '
      'default watchdog — the invariant binds out of the box', () {
    final floor = wireLadderWorstCase(bodyBytes: 0, members: 1).inSeconds;
    expect(floor, greaterThan(300),
        reason: '4×(30+5) + 3×60 = 320s even with no body and no pool');
  });
}
