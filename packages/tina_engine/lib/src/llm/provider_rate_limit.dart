import 'dart:async';

import '../tools/tool.dart';
import 'message.dart';
import 'provider.dart';

/// Built-in per-provider request spacing + concurrency cap, shared by every
/// [LlmProvider] built from the same [ProviderRegistry] descriptor.
///
/// Hosted endpoints rate-limit per API key — a key maps to one provider here —
/// and the app legitimately runs many agents on one provider at once (the
/// first-load folder survey's scouts, delegated sub-agents, workflow nodes, a
/// side panel plus the main chat). A full-width fan-out trips the endpoint's
/// per-key limit (NVIDIA NIM 429s in the wild), which killed whole runs. This
/// limiter has two knobs, matching the two shapes of hosted limits:
///
/// * [minInterval] — request STARTS on one provider are spaced at least this
///   far apart (the requests-per-second semantic). A long streaming turn
///   doesn't block the next request's slot beyond the interval.
/// * [maxConcurrent] — at most this many requests per provider are on the
///   wire at once (the concurrent-requests semantic). Extras park in FIFO
///   order until [release] frees a permit.
///
/// Per-key overrides: [setMinInterval] installs a key-specific spacing that
/// replaces [minInterval] for that key alone (the override wins, the global
/// is the fallback — see [minIntervalFor]). That is how a provider with a
/// known per-key ceiling (NVIDIA NIM 429s at 40 req/min) throttles itself to
/// it by default while every other provider keeps the registry-wide default,
/// and how a user can override per provider (`[providers.<id>]
/// requests_per_minute`) ahead of the built-in hint.
///
/// Start-time slot reservation is FIFO by [acquire] call order and needs no
/// queue structure: each caller is handed the next free launch time on its
/// key and waits out its own delay in parallel with the others. Concurrency
/// permits DO need a queue ([_waiters]) because they're freed by completion,
/// not by time.
class ProviderRateLimiter {
  /// Minimum spacing between request starts on one provider. [Duration.zero]
  /// disables spacing — acquire then only enforces [maxConcurrent].
  Duration minInterval;

  /// Maximum requests per provider in flight at once. Zero (the default)
  /// disables the cap — acquire then only enforces [minInterval].
  int maxConcurrent;

  /// Monotonic clock. A [Stopwatch] (not [DateTime.now]) so the limiter can't
  /// stall or fire early across a wall-clock adjustment.
  final Stopwatch _clock = Stopwatch()..start();

  /// Per-key override for [minInterval]: when set, this interval replaces the
  /// global for requests with this queue key. Absent means use [minInterval].
  final Map<String, Duration> _minIntervalByKey = {};

  /// Per provider id: the launch time reserved for the NEXT requester. Absent
  /// means the provider is idle; a stale past time is treated as "free now".
  final Map<String, Duration> _nextFreeAt = {};

  /// Per provider id: the current 429 backoff penalty (see [defer]). Absent
  /// means no recent 429 — the next one starts a fresh penalty.
  final Map<String, Duration> _penalties = {};

  /// Per provider id: requests currently on the wire (see [maxConcurrent]).
  final Map<String, int> _inFlight = {};

  /// Per provider id: FIFO of acquirers parked waiting for a concurrency
  /// permit. The permit is handed off directly by [release] (the leaving
  /// request's decrement and the waiter's increment cancel out), so the
  /// in-flight count doesn't change on a handoff.
  final Map<String, List<Completer<void>>> _waiters = {};

  /// Cap on the 429 backoff penalty so a persistently hostile endpoint can't
  /// park a provider for minutes at a time.
  static const _maxPenalty = Duration(seconds: 60);

  /// Install (or replace) the minimum interval for ONE queue key: from now on
  /// [acquire]s on [key] space at [interval] apart, overriding the registry
  /// global [minInterval] for that key alone. [Duration.zero] EXPLICITLY
  /// disables spacing for [key] (it does not fall back to the global — it
  /// beats it). Keys with no override keep the global. The effective interval
  /// is read via [minIntervalFor], which is `minIntervalByKey[key] ?? minInterval`.
  void setMinInterval(String key, Duration interval) {
    _minIntervalByKey[key] = interval;
  }

  /// The effective [minInterval] for [key]: the per-key override when
  /// installed (including an explicit [Duration.zero] = spacing disabled),
  /// else the registry-wide [minInterval].
  Duration minIntervalFor(String key) => _minIntervalByKey[key] ?? minInterval;

  ProviderRateLimiter(
      {this.minInterval = Duration.zero, this.maxConcurrent = 0});

  /// Await the launch slot for [providerId]: the next spaced start time, then
  /// a concurrency permit. The start-time slot is reserved synchronously at
  /// call (call order = service order); the concurrency permit is taken (or
  /// parked for) once that time arrives. Completes without parking when both
  /// knobs are disabled or their constraints are already satisfied.
  Future<void> acquire(String providerId) async {
    final interval = minIntervalFor(providerId);
    if (interval > Duration.zero) {
      final now = _clock.elapsed;
      var slot = _nextFreeAt[providerId] ?? Duration.zero;
      if (slot < now) slot = now;
      _nextFreeAt[providerId] = slot + interval;
      final wait = slot - now;
      if (wait > Duration.zero) await Future<void>.delayed(wait);
    }
    final cap = maxConcurrent;
    if (cap > 0) {
      final live = (_inFlight[providerId] ?? 0) + 1;
      if (live <= cap) {
        _inFlight[providerId] = live;
      } else {
        final waiter = Completer<void>();
        _waiters.putIfAbsent(providerId, () => []).add(waiter);
        await waiter.future;
      }
    }
  }

  /// Return the concurrency permit taken by an [acquire] that completed —
  /// call exactly once per acquire, when the request leaves the wire (stream
  /// done, cancelled, or the waiter itself was cancelled after the fact).
  /// Hands the permit straight to the next FIFO waiter when one is parked;
  /// with no cap configured this is a no-op.
  void release(String providerId) {
    if (maxConcurrent <= 0) return;
    final q = _waiters[providerId];
    if (q != null && q.isNotEmpty) {
      q.removeAt(0).complete();
      return; // handoff: count unchanged
    }
    final live = _inFlight[providerId] ?? 0;
    if (live <= 1) {
      _inFlight.remove(providerId);
    } else {
      _inFlight[providerId] = live - 1;
    }
  }

  /// Push the provider's queue forward after a 429: subsequent [acquire]s
  /// wait out the penalty before launching. The penalty starts at four
  /// intervals and doubles per consecutive 429 (capped at [_maxPenalty]);
  /// [reportSuccess] resets it, so spacing self-tunes to whatever per-key
  /// limit the endpoint actually enforces — the configured [minInterval] is
  /// only a floor, not a guess that has to be right.
  ///
  /// Already-parked waiters keep their reserved launch times (their delay was
  /// fixed at acquire); they may launch into the penalty window and 429 again,
  /// which just extends it. Convergence over precision — no queue surgery.
  void defer(String providerId) {
    final interval = minIntervalFor(providerId);
    if (interval <= Duration.zero) return;
    // Seed with 2× so the first 429 lands on 4×interval, then doubles.
    final base = _penalties[providerId] ?? interval * 2;
    final next = base * 2;
    final penalty = next > _maxPenalty ? _maxPenalty : next;
    _penalties[providerId] = penalty;
    final target = _clock.elapsed + penalty;
    final cur = _nextFreeAt[providerId];
    if (cur == null || cur < target) _nextFreeAt[providerId] = target;
  }

  /// A clean (non-429) response completed on [providerId]: reset its backoff
  /// penalty so the next 429 starts over at the floor.
  void reportSuccess(String providerId) => _penalties.remove(providerId);

  /// Forget all slot reservations (tests). Does not affect in-flight waits.
  void reset() {
    _nextFreeAt.clear();
    _penalties.clear();
    _inFlight.clear();
    _minIntervalByKey.clear();
    for (final q in _waiters.values) {
      for (final w in q) {
        if (!w.isCompleted) w.complete();
      }
    }
    _waiters.clear();
  }
}

/// Opaque queue key for one upstream: hosted per-key limits are identified by
/// the endpoint + API key, NOT by our descriptor id — two config providers
/// pointing at the same server with the same key share one limit and must
/// share one queue. Hashed (FNV-1a over `baseUrl\0apiKey`) so the raw key can
/// never leak into logs or debug prints via the limiter's state.
String providerQueueKey(String baseUrl, String apiKey) {
  // Dart VM ints are 64-bit two's complement; FNV-1a's multiply wraps.
  var h = 0xcbf29ce484222325;
  for (final c in '$baseUrl\x00$apiKey'.codeUnits) {
    h ^= c;
    h *= 0x100000001b3;
  }
  return 'q${h.toRadixString(16)}';
}

/// Decorates an [LlmProvider] with its descriptor's [ProviderRateLimiter]:
/// each [send] awaits a launch slot (spacing) and a concurrency permit before
/// subscribing to the inner stream, and releases the permit when the request
/// leaves the wire. With spacing off for this provider's key AND no
/// concurrency cap it forwards untouched — no controller, no extra microtask.
///
/// Like [MeteringProvider], the stream is controller-backed (not `async*`) so
/// cancelling the subscription while parked on a slot tears down promptly and
/// never subscribes to the inner provider. A cancelled waiter's reserved start
/// slot is simply forfeited (the timer fires into the void); a permit acquired
/// by an already-cancelled waiter is released the moment [ProviderRateLimiter
/// .acquire] completes, so cancellation can never leak a concurrency permit.
class RateLimitedProvider implements LlmProvider {
  final LlmProvider inner;
  final ProviderRateLimiter limiter;

  /// The queue this send waits on — [providerQueueKey]'s endpoint+key hash,
  /// not a descriptor id (see there for why).
  final String limitKey;

  RateLimitedProvider(this.inner, this.limiter, this.limitKey);

  /// Delegate so `/model <name>` (which assigns `provider.model = next`)
  /// reaches the real underlying provider rather than a dead field here.
  @override
  String get model => inner.model;
  @override
  set model(String value) {
    inner.model = value;
  }

  @override
  void close() => inner.close();

  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) {
    // Fast path: read the EFFECTIVE interval for THIS queue key (per-key
    // override, else the global) — the same value [ProviderRateLimiter.acquire]
    // would enforce — so a key with an installed spacing is never bypassed by
    // a disabled global, and a key with spacing disabled stays unwrapped-fast.
    if (limiter.minIntervalFor(limitKey) <= Duration.zero &&
        limiter.maxConcurrent <= 0) {
      return inner.send(system: system, messages: messages, tools: tools);
    }
    late StreamController<StreamEvent> controller;
    StreamSubscription<StreamEvent>? innerSub;
    final cancelled = Completer<void>();

    // Release the concurrency permit exactly once per completed acquire —
    // whichever exit fires first (stream done, downstream cancel, or the
    // waiter itself was cancelled after acquiring).
    var permitReleased = false;
    void releasePermit() {
      if (permitReleased) return;
      permitReleased = true;
      limiter.release(limitKey);
    }

    Future<void> run() async {
      await limiter.acquire(limitKey);
      // Cancelled while parked (slot or permit): the acquire may have taken a
      // permit anyway — hand it straight back and never touch the wire.
      if (cancelled.isCompleted) {
        releasePermit();
        return;
      }
      var saw429 = false;
      innerSub = inner
          .send(system: system, messages: messages, tools: tools)
          .listen(
            (event) {
              // A 429 means the endpoint's real per-key limit is below our
              // current spacing — widen the queue for every subsequent
              // request (see defer). The policy retry above (and the
              // scout/host-level retry) then re-acquires into the penalty.
              if (event is StreamError && event.statusCode == 429) {
                saw429 = true;
                limiter.defer(limitKey);
              }
              if (!controller.isClosed) controller.add(event);
            },
            onError: (Object e, StackTrace st) {
              if (!controller.isClosed) controller.addError(e, st);
            },
            onDone: () {
              releasePermit();
              // A clean completion resets the backoff floor — but not when
              // the same stream carried a 429 (it completes normally after
              // yielding the StreamError event).
              if (!saw429) limiter.reportSuccess(limitKey);
              if (!controller.isClosed) controller.close();
            },
          );
    }

    controller = StreamController<StreamEvent>(
      onListen: () => unawaited(run()),
      onCancel: () {
        if (!cancelled.isCompleted) cancelled.complete();
        // Only the side that owns a subscription releases here — a waiter
        // still parked in acquire releases from run() when it completes.
        if (innerSub != null) releasePermit();
        return innerSub?.cancel();
      },
    );
    return controller.stream;
  }
}
