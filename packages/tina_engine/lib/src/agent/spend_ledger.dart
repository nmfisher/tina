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

  /// #46 (b): estimated input-token spend from failed transport attempts that
  /// carried no provider-reported usage (each failed attempt gets the estimate
  /// of the body it re-sent). Always reported separately from measured spend
  /// — `totalTokens` is measured only, `totalEstimatedTokens` is estimated only,
  /// and `/spend` shows "X measured + Y estimated" so estimates never masquerade.
  int _totalEstimatedTokens = 0;

  /// #46 (c): spend booked for RETRIED transport attempts — every failed
  /// attempt, whether its tokens were measured from the error body or
  /// estimated from the re-sent body size. This is the numerator of the
  /// degrading-provider notice ([onRetriedSpendNotice]): retried spend
  /// growing past a tenth of total spend means the provider stack is
  /// burning money re-sending bodies, and the user should hear about it
  /// while it happens — not only on the bill.
  int _retriedTokens = 0;
  int _retriedEstimated = 0;
  int _retriedMeasured = 0;

  /// Highest 10-percentage-point band the retried-spend notice has fired
  /// for. The notice escalates — it fires again only when retried spend
  /// crosses the NEXT band, so a degrading patch that keeps retrying keeps
  /// escalating rather than spamming per attempt.
  int _retriedNoticeBand = 0;

  /// #46 (c): sink for the retried-spend notice. Installed by the app
  /// composition (stderr by default — visible headless and in nohup logs);
  /// a TUI may replace it with a chat renderer. Null disables the notice
  /// (tests install their own collector or leave it null).
  void Function(String notice)? onRetriedSpendNotice;

  /// Retried transport spend booked this session ([recordRetried]).
  int get retriedTokens => _retriedTokens;

  /// Of [retriedTokens], the portion that was provider-measured (the error
  /// body carried usage) vs estimated (body-size floor).
  int get retriedMeasured => _retriedMeasured;
  int get retriedEstimated => _retriedEstimated;

  /// Tokens restored from a previous process ([seed]); the part of
  /// [totalTokens] that predates this process. Shown by `/spend` so the
  /// restored portion is visible. Seeding never trips the ceiling — the cap
  /// guards what THIS process spends, not history.
  int _seededTokens = 0;

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
  /// MEASURED spend only — provider-reported usage. Estimated spend from
  /// failed attempts is tracked separately in [totalEstimatedTokens] so the
  /// two are never conflated; the trip arithmetic reads BOTH (see
  /// [_tripCheck]).
  int get totalTokens => _totalTokens;

  /// #46 (b): running total of ESTIMATED tokens (failed-attempt approximations
  /// booked via [recordEstimated]). Reported distinctly from [totalTokens];
  /// counts toward the same ceiling so a runaway retry ladder trips it.
  int get totalEstimatedTokens => _totalEstimatedTokens;

  /// Convenience read for the trip/display arithmetic: measured + estimated.
  int get grandTotalTokens => _totalTokens + _totalEstimatedTokens;

  /// The ceiling-crossing test over the COMBINED total (#46: estimated spend
  /// must trip the global ceiling like measured spend, because the point of
  /// the estimate is that the caps read low today).
  bool get _overCeiling =>
      maxGlobalTokens > 0 && grandTotalTokens > maxGlobalTokens;

  /// Tokens restored from a previous run via [seed] (the persisted portion of
  /// [totalTokens]).
  int get seededTokens => _seededTokens;

  /// The ceiling in effect, or `null` when unbounded (`maxGlobalTokens == 0`).
  int? get cap => maxGlobalTokens == 0 ? null : maxGlobalTokens;

  /// The configured RPM, or `0` when the throttle is disabled.
  int get rpm => requestsPerMinute;

  /// Latched `true` once the global ceiling was crossed. Stays true for the
  /// rest of the session (only [reset] clears it).
  bool get tripped => _tripped;

  /// The trip reason, set once when the ceiling is first crossed.
  String? get reason => _reason;

  /// Record one request's MEASURED usage (provider-reported). Sums
  /// `input + output` into the running total and, if that crosses
  /// [maxGlobalTokens], latches [tripped] + [reason] exactly once.
  ///
  /// This books the measured counter only. Usage flagged
  /// [TokenUsage.estimated] is routed to [recordEstimated] so the two
  /// counters can never be conflated, no matter who calls this.
  void record(TokenUsage usage) {
    if (usage.estimated) {
      recordEstimated(usage);
      return;
    }
    _totalTokens += usage.inputTokens + usage.outputTokens;
    _tripCheck();
  }

  /// #46 (b): record one failed transport attempt's ESTIMATED usage — the
  /// size of the body it re-sent, booked because its error carried no
  /// provider-reported usage. The estimate counts toward the SAME
  /// [maxGlobalTokens] ceiling (the point of #46: the caps read low today and
  /// a runaway retry ladder must still trip them), but it lives in its own
  /// counter ([totalEstimatedTokens]) so `/spend` can report "X measured +
  /// Y estimated" and estimates never masquerade as measured.
  void recordEstimated(TokenUsage usage) {
    _totalEstimatedTokens += usage.inputTokens + usage.outputTokens;
    _tripCheck();
  }

  /// #46 (c): book one RETRIED transport attempt — the single funnel entry
  /// for failed-attempt spend. Routes the tokens into the measured or
  /// estimated counter exactly as the raw paths do, AND accumulates the
  /// retried-spend tallies that drive the degrading-provider notice
  /// ([onRetriedSpendNotice]): once retried spend crosses a tenth of total
  /// spend, and again at each further tenth, the ledger says so — a provider
  /// patch that keeps failing keeps re-sending the full body, and that burn
  /// belongs in front of the user, not only on the bill.
  void recordRetried(TokenUsage usage, {required bool estimated}) {
    final used = usage.inputTokens + usage.outputTokens;
    _retriedTokens += used;
    if (estimated) {
      _retriedEstimated += used;
      recordEstimated(usage);
    } else {
      _retriedMeasured += used;
      record(usage);
    }
    _retriedBandCheck();
  }

  /// Retried-spend notice bands are 10% of the running grand total. Below
  /// [kRetriedNoticeMinTokens] nothing fires — a thousand retried tokens is
  /// noise on a tiny session, not a degrading provider.
  static const kRetriedNoticeMinTokens = 1000;

  void _retriedBandCheck() {
    final sink = onRetriedSpendNotice;
    if (sink == null) return;
    final grand = grandTotalTokens;
    if (grand <= 0 || _retriedTokens < kRetriedNoticeMinTokens) return;
    final pct = _retriedTokens * 100 / grand;
    final band = (pct / 10).floor();
    if (band <= _retriedNoticeBand) return;
    _retriedNoticeBand = band;
    sink('[retries] failed-attempt spend $_retriedTokens tokens '
        '(${pct.toStringAsFixed(0)}% of $grand total; '
        '$_retriedEstimated estimated + $_retriedMeasured measured) — '
        'a provider is degrading and the ladders are re-sending full bodies');
  }

  /// Latches [tripped] + [reason] exactly once, when the COMBINED
  /// measured+estimated total crosses [maxGlobalTokens]. Keeps counting after
  /// the trip (the totals keep growing for `/spend`) but never rewrites the
  /// first trip reason.
  void _tripCheck() {
    if (_tripped) return;
    if (_overCeiling) {
      _tripped = true;
      _reason = 'global token spend ceiling exceeded '
          '($grandTotalTokens > $maxGlobalTokens, of which '
          '$_totalEstimatedTokens estimated). Raise [limits] max_global_tokens '
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

  /// Seed the running total from a persisted session record (resume/session
  /// switch). Replaces the total and the seeded portion; never trips the
  /// ceiling (the cap guards what this process spends, not restored history).
  void seed(int tokens) {
    _seededTokens = tokens < 0 ? 0 : tokens;
    _totalTokens = _seededTokens;
  }

  /// Merge another ledger's totals into this one (e.g. the summary fleet's
  /// ephemeral ledger after an in-process `/index` run). Measured and
  /// estimated merge into their own counters — never mixed — and the trip
  /// check applies over the combined total: a fleet that pushes the session
  /// past its ceiling trips it.
  void merge(SpendLedger other) {
    if (other.grandTotalTokens <= 0) return;
    _totalTokens += other.totalTokens;
    _totalEstimatedTokens += other.totalEstimatedTokens;
    _tripCheck();
  }

  /// Zero all state. For tests / a future explicit reset command — NOT wired to
  /// `/clear`, by design (see class docs).
  void reset() {
    _totalTokens = 0;
    _totalEstimatedTokens = 0;
    _retriedTokens = 0;
    _retriedEstimated = 0;
    _retriedMeasured = 0;
    _retriedNoticeBand = 0;
    _seededTokens = 0;
    _tripped = false;
    _reason = null;
    _tokens = requestsPerMinute.toDouble();
    _lastRefill = _now();
  }
}
