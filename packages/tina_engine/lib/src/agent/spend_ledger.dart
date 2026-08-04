import 'dart:async';

import '../llm/provider.dart';

/// Emitted (inside a [StreamError]) by [MeteringProvider] when the global token
/// ceiling has been crossed. The agent's stream consumer surfaces it as a turn
/// error — the same path any provider error takes to abort a turn — so a tripped
/// ledger stops further model work without bespoke plumbing.
class SpendLimitExceeded implements Exception {
  final String reason;
  const SpendLimitExceeded(this.reason);

  @override
  String toString() => 'SpendLimitExceeded: $reason';
}

/// Session-scoped accumulator of model spend across **every** agent (the main
/// session + the startup orchestrator + all scouts/sub-agents). Fed by
/// [MeteringProvider] at the provider boundary — the single funnel — so even
/// requests that bypass the per-agent [TokenBudget] (e.g. `Agent.compact`) are
/// counted here.
///
/// Two independent guards live here:
///
/// - A **global token ceiling** ([maxGlobalTokens]): once [record] pushes the
///   running total past it, [tripped] latches `true` and every later request is
///   refused (hard-abort). `0` = unbounded.
/// - An **RPM token-bucket** ([requestsPerMinute]): [acquireRequestSlot] spaces
///   outbound requests in time. `0` = disabled (the common case).
///
/// Token accounting matches [TokenBudget.record] — `inputTokens + outputTokens`
/// only. Cache-creation/cache-read tokens are excluded for now (they would need
/// per-model pricing to denominate honestly); revisit when a USD estimate is
/// wired in.
///
/// The ledger is **app-session-scoped** (one per `buildAppComposition`), spanning
/// all conversations. It is deliberately NOT reset by `/clear` — resetting on
/// clear would let a runaway loop escape the hard ceiling by clearing. [reset]
/// exists for tests; production resets only on restart.
class SpendLedger {
  /// Hard global token ceiling across all agents. `0` = unbounded.
  final int maxGlobalTokens;

  /// Outbound requests-per-minute cap. `0` = throttle disabled.
  final int requestsPerMinute;

  int _totalTokens = 0;
  bool _tripped = false;
  String? _reason;

  // Token-bucket state. Capacity = requestsPerMinute; refills at rpm/60 tokens
  // per second. Polled (not completer-queued) so a blocked acquire is cheap to
  // cancel: [acquireRequestSlot] races its wait against an optional cancel
  // signal rather than parking on a Completer.
  double _tokens;
  DateTime _lastRefill;

  /// Wall clock, injectable for deterministic throttle tests. Defaults to real
  /// time. (App code — not a workflow script — so a live clock is fine here.)
  final DateTime Function() _now;

  /// Polling granularity for the RPM wait. Bounds both throttle latency and
  /// (via the cancel race) cancel latency to one tick.
  static const _tick = Duration(milliseconds: 100);

  SpendLedger({
    required this.maxGlobalTokens,
    required this.requestsPerMinute,
    DateTime Function()? now,
  })  : _tokens = requestsPerMinute.toDouble(),
        _lastRefill = now?.call() ?? DateTime.now(),
        _now = now ?? DateTime.now;

  /// Running total of `input + output` tokens recorded this session.
  int get totalTokens => _totalTokens;

  /// The ceiling in effect, or `null` when unbounded (`maxGlobalTokens == 0`).
  int? get cap => maxGlobalTokens == 0 ? null : maxGlobalTokens;

  /// The configured RPM, or `0` when the throttle is disabled.
  int get rpm => requestsPerMinute;

  /// Latched `true` once the global ceiling was crossed. Stays true for the
  /// rest of the session (only [reset] clears it).
  bool get tripped => _tripped;

  /// The trip reason, set once when the ceiling is first crossed.
  String? get reason => _reason;

  /// Record one request's usage. Sums `input + output` into the running total
  /// and, if that crosses [maxGlobalTokens], latches [tripped] + [reason]
  /// exactly once. A no-op for usage that's already empty.
  void record(TokenUsage usage) {
    if (tripped) {
      // Keep counting for the /spend total even after tripping, but never
      // rewrite the first trip reason.
      _totalTokens += usage.inputTokens + usage.outputTokens;
      return;
    }
    _totalTokens += usage.inputTokens + usage.outputTokens;
    if (maxGlobalTokens > 0 && _totalTokens > maxGlobalTokens) {
      _tripped = true;
      _reason = 'global token spend ceiling exceeded '
          '($_totalTokens > $maxGlobalTokens). Raise [limits] max_global_tokens '
          '(or --max-global-tokens) in ~/.tina/config, or restart tina.';
    }
  }

  /// Acquire one RPM slot. Completes with `true` when a slot is granted (or when
  /// the throttle is disabled), `false` when aborted via [cancelSignal] (in
  /// which case no token is consumed).
  ///
  /// The wait is polled at [_tick] granularity and raced against [cancelSignal]
  /// so a cancel returns within one tick rather than blocking until a token
  /// refills. `_tryConsume` is synchronous (check + decrement with no await in
  /// between), so concurrent acquires can't over-grant — the single-threaded
  /// event loop makes the consume atomic.
  Future<bool> acquireRequestSlot({Future<void>? cancelSignal}) async {
    if (requestsPerMinute <= 0) return true;
    while (true) {
      if (_tryConsume(_now())) return true;
      final tick = Future<bool>.delayed(_tick, () => false); // false = keep waiting
      if (cancelSignal == null) {
        await tick;
        continue;
      }
      // Race the tick against cancel; if cancel wins, abort without consuming.
      // (Both futures return bools, not voids, so the winner is identifiable by
      // value — Future.any returns the *result*, not the future itself.)
      final cancelled = await Future.any<bool>([tick, cancelSignal.then((_) => true)]);
      if (cancelled) return false;
    }
  }

  /// Refill the bucket to the present, then consume one token if available.
  bool _tryConsume(DateTime now) {
    _refill(now);
    if (_tokens >= 1) {
      _tokens -= 1;
      return true;
    }
    return false;
  }

  /// Add tokens accrued since the last refill, clamped to capacity.
  void _refill(DateTime now) {
    final elapsed = now.difference(_lastRefill);
    _lastRefill = now;
    if (elapsed <= Duration.zero) return;
    final added = elapsed.inMicroseconds / 1e6 * (requestsPerMinute / 60.0);
    _tokens =
        (_tokens + added).clamp(0.0, requestsPerMinute.toDouble());
  }

  /// Zero all state. For tests / a future explicit reset command — NOT wired to
  /// `/clear`, by design (see class docs).
  void reset() {
    _totalTokens = 0;
    _tripped = false;
    _reason = null;
    _tokens = requestsPerMinute.toDouble();
    _lastRefill = _now();
  }
}
