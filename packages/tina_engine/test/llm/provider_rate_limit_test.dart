import 'dart:async';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

/// A stub provider that records when each [send] STARTS (i.e. when the inner
/// stream is actually subscribed) and never completes on its own.
class _RecordingProvider extends LlmProvider {
  final List<DateTime> starts;
  _RecordingProvider(this.starts) : super('recording');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    starts.add(DateTime.now());
    yield const TextDelta('ok');
    yield MessageComplete(
      content: const [TextBlock('ok')],
      stopReason: 'end_turn',
      usage: TokenUsage.zero,
    );
  }
}

void main() {
  group('ProviderRateLimiter', () {
    test('zero interval (default) never waits', () async {
      final limiter = ProviderRateLimiter();
      final watch = Stopwatch()..start();
      for (var i = 0; i < 5; i++) {
        await limiter.acquire('nim');
      }
      expect(watch.elapsedMilliseconds, lessThan(50),
          reason: 'disabled limiter completes synchronously');
    });

    test('concurrent acquires on one key start at least minInterval apart',
        () async {
      final limiter = ProviderRateLimiter(
          minInterval: const Duration(milliseconds: 40));
      final watch = Stopwatch()..start();
      final t0 = <int>[];
      await Future.wait([
        for (var i = 0; i < 4; i++)
          limiter.acquire('nim').then((_) => t0.add(watch.elapsedMilliseconds)),
      ]);
      t0.sort();
      // The k-th waiter launches at ~k*interval. Allow scheduling slop, but
      // require real spacing between the first and the last.
      expect(t0.last - t0.first, greaterThanOrEqualTo(3 * 40 - 10),
          reason: '4 waiters spaced 40ms: last ≈ 120ms after first');
    });

    test('separate keys do not block each other', () async {
      final limiter = ProviderRateLimiter(
          minInterval: const Duration(milliseconds: 80));
      final watch = Stopwatch()..start();
      await Future.wait(
          [limiter.acquire('nim'), limiter.acquire('anthropic')]);
      expect(watch.elapsedMilliseconds, lessThan(50),
          reason: 'each provider has its own slot queue');
    });

    test('an idle gap releases the slot (no burst penalty)', () async {
      final limiter = ProviderRateLimiter(
          minInterval: const Duration(milliseconds: 30));
      await limiter.acquire('nim');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      final watch = Stopwatch()..start();
      await limiter.acquire('nim');
      expect(watch.elapsedMilliseconds, lessThan(20),
          reason: 'after a quiet period the next request starts immediately');
    });

    test('defer pushes the next launch past the penalty window', () async {
      final limiter = ProviderRateLimiter(
          minInterval: const Duration(milliseconds: 25));
      await limiter.acquire('nim'); // provider now idle again
      limiter.defer('nim'); // a 429 escaped
      final watch = Stopwatch()..start();
      await limiter.acquire('nim');
      // First penalty = 4 × interval = 100ms (minus scheduling slop).
      expect(watch.elapsedMilliseconds,
          greaterThanOrEqualTo(4 * 25 - 10),
          reason: 'a 429 defers the queue by 4 intervals');
      // reportSuccess resets the floor: the next defer is 4× again, not 8×.
      limiter.reportSuccess('nim');
      limiter.defer('nim');
      final watch2 = Stopwatch()..start();
      await limiter.acquire('nim');
      expect(watch2.elapsedMilliseconds, lessThan(4 * 25 + 40),
          reason: 'success resets the doubling');
    });

    test('consecutive defers double the penalty, capped at 60s', () async {
      final limiter = ProviderRateLimiter(
          minInterval: const Duration(seconds: 1));
      limiter.defer('nim'); // 4s
      limiter.defer('nim'); // 8s
      limiter.defer('nim'); // 16s
      limiter.defer('nim'); // 32s
      limiter.defer('nim'); // 60s (capped, not 64s)
      // The reserved next-free must sit ~60s out: acquiring now must still
      // be parked a beat later (it would complete immediately if the penalty
      // were dropped or clamped into the past).
      var launched = false;
      unawaited(limiter.acquire('nim').then((_) => launched = true));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(launched, isFalse,
          reason: 'the capped 60s penalty still holds the queue');
    });

    test('maxConcurrent parks the third acquirer until release', () async {
      final limiter = ProviderRateLimiter(maxConcurrent: 2);
      // Both knobs independent: no spacing, only the cap.
      final a = Completer<void>(), b = Completer<void>(), c = Completer<void>();
      unawaited(limiter.acquire('nim').then((_) => a.complete()));
      unawaited(limiter.acquire('nim').then((_) => b.complete()));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(a.isCompleted && b.isCompleted, isTrue,
          reason: 'first two take permits at once');
      unawaited(limiter.acquire('nim').then((_) => c.complete()));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(c.isCompleted, isFalse, reason: 'third parks at the cap');

      limiter.release('nim'); // first request finishes
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(c.isCompleted, isTrue, reason: 'release hands off the permit');

      // Permits are per provider: another key is unaffected.
      final d = Completer<void>();
      unawaited(limiter.acquire('anthropic').then((_) => d.complete()));
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(d.isCompleted, isTrue);
    });

    test('maxConcurrent 0 (default) is uncapped', () async {
      final limiter = ProviderRateLimiter();
      final done = [
        for (var i = 0; i < 5; i++) Completer<void>(),
      ];
      for (var i = 0; i < 5; i++) {
        unawaited(limiter.acquire('nim').then((_) => done[i].complete()));
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      for (final c in done) {
        expect(c.isCompleted, isTrue, reason: 'no cap → nothing parks');
      }
    });
  });

  group('RateLimitedProvider via ProviderRegistry.build', () {
    ProviderRegistry registryWith(LlmProvider provider,
        {Duration? minInterval}) {
      final r = ProviderRegistry(env: const {'TEST_KEY': 'k'});
      r.register(ProviderDescriptor(
        id: 'stub',
        name: 'stub',
        authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
        defaultBaseUrl: 'https://example.test',
        builder: (_) => provider,
        models: const {
          'm': ModelInfo(id: 'm', name: 'm', contextWindow: 1, maxOutput: 1),
        },
      ));
      if (minInterval != null) r.rateLimiter.minInterval = minInterval;
      return r;
    }

    test('concurrent sends through one provider are spaced', () async {
      final starts = <DateTime>[];
      final registry =
          registryWith(_RecordingProvider(starts), minInterval: const Duration(milliseconds: 50));
      final provider = registry.build('stub/m');

      await Future.wait([
        for (var i = 0; i < 3; i++)
          provider
              .send(
                  system: 's',
                  messages: const [
                    Message(role: Role.user, content: [TextBlock('hi')])
                  ],
                  tools: const [])
              .toList(),
      ]);

      expect(starts, hasLength(3));
      for (var i = 1; i < starts.length; i++) {
        final gap = starts[i].difference(starts[i - 1]).inMilliseconds;
        expect(gap, greaterThanOrEqualTo(40),
            reason: 'request starts are spaced by (nearly) the interval');
      }
    });

    test('disabled by default: sends pass straight through', () async {
      final starts = <DateTime>[];
      final registry = registryWith(_RecordingProvider(starts));
      final provider = registry.build('stub/m');

      final watch = Stopwatch()..start();
      await Future.wait([
        for (var i = 0; i < 3; i++)
          provider
              .send(
                  system: 's',
                  messages: const [
                    Message(role: Role.user, content: [TextBlock('hi')])
                  ],
                  tools: const [])
              .toList(),
      ]);
      expect(watch.elapsedMilliseconds, lessThan(50),
          reason: 'no spacing unless the composition root opts in');
    });

    test('cancelling while parked on a slot never subscribes the inner send',
        () async {
      final starts = <DateTime>[];
      final registry =
          registryWith(_RecordingProvider(starts), minInterval: const Duration(milliseconds: 500));
      final provider = registry.build('stub/m');

      // First send holds the slot; the second parks for ~500ms and is
      // cancelled immediately — it must never reach the inner provider.
      final first = provider.send(
          system: 's',
          messages: const [Message(role: Role.user, content: [TextBlock('a')])],
          tools: const []);
      final second = provider.send(
          system: 's',
          messages: const [Message(role: Role.user, content: [TextBlock('b')])],
          tools: const []);
      final sub = second.listen(null);
      await sub.cancel();
      await first.toList();

      expect(starts, hasLength(1),
          reason: 'the cancelled waiter forfeited its slot pre-wire');
    });

    test('a 429 StreamError defers the queue; a clean stream resets it',
        () async {
      // The inner provider answers the FIRST send with a 429 that escaped the
      // transport's own retries (openai_compatible yields it as a StreamError
      // event carrying statusCode), then subsequent sends succeed.
      final inner = _EventPerCallProvider((call) => call == 0
          ? const StreamError('NIM 429: Too Many Requests', statusCode: 429)
          : const TextDelta('ok'));
      final registry = registryWith(inner,
          minInterval: const Duration(milliseconds: 25));
      final provider = registry.build('stub/m');

      Future<void> send() => provider
          .send(
              system: 's',
              messages: const [Message(role: Role.user, content: [TextBlock('x')])],
              tools: const [])
          .toList();

      await send(); // 429 → defer('stub'): the queue now holds ~100ms.
      final watch = Stopwatch()..start();
      await send(); // The scout/host-level retry, into the penalty window.
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(4 * 25 - 10),
          reason: 'the next request waits out the 429 penalty');

      // A clean completion resets the floor: no penalty remains.
      await send();
      final watch2 = Stopwatch()..start();
      await send();
      expect(watch2.elapsedMilliseconds, lessThan(4 * 25),
          reason: 'reportSuccess cleared the backoff penalty');
    });

    test('maxConcurrent caps inner streams; done and cancel both free permits',
        () async {
      final inner = _GatedProvider();
      final registry = registryWith(inner, minInterval: const Duration(milliseconds: 5))
        ..rateLimiter.maxConcurrent = 2;
      final provider = registry.build('stub/m');

      StreamSubscription<StreamEvent> send() =>
          provider.send(system: 's', messages: const [], tools: const []).listen(null);

      // Four requests; only two may reach the inner provider at once.
      final subs = [send(), send(), send(), send()];
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(inner.peak, 2,
          reason: 'the cap holds the extra two in the FIFO queue');

      // Completing an in-flight stream releases its permit → one queued
      // request proceeds (still at the cap, never above).
      inner.finish(0);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(inner.peak, 2);
      expect(inner.launched, 3,
          reason: 'a finished stream handed its permit to a queued request');

      // Cancelling another in-flight one ALSO frees its permit.
      await subs[1].cancel();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(inner.launched, 4,
          reason: 'cancel released the permit for the last queued request');

      await inner.closeAll();
      for (final s in subs) {
        await s.cancel();
      }
    });
  });

  group('policy stack composition (the bypass invariants)', () {
    // These pin the property the old transport-internal retry broke: a wire
    // re-attempt re-enters the WHOLE stack, and one upstream identity shares
    // one queue no matter how many descriptors point at it.
    ProviderDescriptor desc(String id, LlmProvider provider) =>
        ProviderDescriptor(
          id: id,
          name: id,
          authSources: const [AuthSource('TEST_KEY', AuthScheme.bearerToken)],
          defaultBaseUrl: 'https://example.test', // SAME upstream for both
          builder: (_) => provider,
          models: const {
            'm': ModelInfo(id: 'm', name: 'm', contextWindow: 1, maxOutput: 1),
          },
        );

    test('a retry re-acquires a rate-limit slot (never bypasses the queue)',
        () async {
      final inner = _EventPerCallProvider((call) => call == 0
          ? const StreamError('429', statusCode: 429,
              retryAfter: Duration(milliseconds: 10))
          : const TextDelta('ok'));
      final r = ProviderRegistry(env: const {'TEST_KEY': 'k'})
        ..register(desc('a', inner));
      r.rateLimiter.minInterval = const Duration(milliseconds: 120);
      r.maxSendRetries = 3;
      final provider = r.build('a/m');

      final watch = Stopwatch()..start();
      await provider
          .send(system: 's', messages: const [], tools: const [])
          .toList();

      expect(inner.attempts, 2, reason: 'exactly one retry');
      // The retry went back through the limiter: with the old
      // transport-internal retry it would fire ~10ms later (the Retry-After
      // hint); through the queue it waits out the spacing (plus the 429's
      // adaptive defer on top).
      expect(watch.elapsedMilliseconds, greaterThanOrEqualTo(100),
          reason: 'the re-attempt waited for a launch slot');
    });

    test('two descriptors on one endpoint+key share one queue', () async {
      final starts = <DateTime>[];
      final r = ProviderRegistry(env: const {'TEST_KEY': 'k'});
      r.register(desc('a', _RecordingProvider(starts)));
      // A DIFFERENT descriptor id — same endpoint + same key. Under
      // descriptor-id keying these two would get separate queues and both
      // fire at once.
      r.register(desc('b', _RecordingProvider(starts)));
      r.rateLimiter.minInterval = const Duration(milliseconds: 100);
      final pa = r.build('a/m');
      final pb = r.build('b/m');

      await Future.wait([
        pa.send(system: 's', messages: const [], tools: const []).toList(),
        pb.send(system: 's', messages: const [], tools: const []).toList(),
      ]);
      expect(starts, hasLength(2));
      final gap = starts[1].difference(starts[0]).inMilliseconds.abs();
      expect(gap, greaterThanOrEqualTo(80),
          reason: 'descriptor ids differ but the upstream key is one — '
              'per-key limits need one queue');
    });
  });
}

/// A stub whose each [send] yields one event (chosen by 0-based call number)
/// then completes — the shape the 429 test needs: an error EVENT on a
/// normally-completing stream, which is how the real providers surface
/// non-200s.
class _EventPerCallProvider extends LlmProvider {
  final StreamEvent Function(int call) _eventFor;
  var _call = 0;
  _EventPerCallProvider(this._eventFor) : super('stub');

  /// How many sends have been consumed (the wire-attempt count).
  int get attempts => _call;

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) async* {
    yield _eventFor(_call++);
  }
}

/// A streaming stub that never completes on its own — each [send] stays open
/// until the test says otherwise — while tracking how many requests are live
/// at once ([peak]) and how many ever launched ([launched]). This is the
/// concurrency-cap shape: the wrapper must not subscribe more than
/// `maxConcurrent` of these at a time.
class _GatedProvider extends LlmProvider {
  final List<StreamController<StreamEvent>> _open = [];
  var live = 0;
  var launched = 0;
  var peak = 0;

  _GatedProvider() : super('gated');

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) {
    launched++;
    live++;
    if (live > peak) peak = live;
    final c = StreamController<StreamEvent>(onCancel: () => live--);
    _open.add(c);
    return c.stream;
  }

  /// Complete the n-th launched request (natural stream end).
  void finish(int n) {
    live--;
    _open[n].close();
  }

  /// Complete everything still open (teardown + final assertions).
  Future<void> closeAll() async {
    for (final c in _open) {
      if (!c.isClosed) {
        live--;
        await c.close();
      }
    }
  }
}
