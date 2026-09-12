import 'dart:async';

/// Attempt-level liveness feed (#45): the transport retry ladder
/// ([RetryingProvider], [PooledProvider], [sendOnce] callers) is
/// agent-event-silent by design, so a run grinding through a bad provider
/// patch was indistinguishable from a wedged one to the headless watchdog.
///
/// The watchdog lives in the app layer, several packages above this code, so
/// a global would be the wrong shape — instead the app installs a callback
/// here ([Wire.onWireEvent]) once at startup and every layer reports its
/// transitions through [Wire.report]. A null hook makes reporting free.
///
/// This library depends only on the SDK — it sits at the bottom of the
/// provider stack so every layer above ([http.dart], [retrying_provider.dart],
/// [pooled_provider.dart]) can depend on it without cycles. The ladder
/// ARITHMETIC that pairs with it ([wireLadderWorstCase],
/// [reconcileWatchdogWithLadder]) lives in http.dart next to the constants it
/// computes from.
///
/// The last reported state is also retained so an aborting watchdog can name
/// what the wire was actually doing (member id, attempt number, elapsed in
/// flight) instead of guessing.
class WireState {
  /// Machine-readable event name, e.g. 'attempt_start', 'backoff',
  /// 'pool_rotate', 'attempt_end'.
  final String event;

  /// Which pool member / endpoint served the attempt ('single' when not
  /// pooled).
  final String member;

  /// 1-based attempt number within the current send.
  final int attempt;

  /// Whether an HTTP request is currently in flight.
  final bool inFlight;

  final DateTime at;
  WireState(this.event,
      {required this.member, required this.attempt, required this.inFlight})
      : at = DateTime.now();

  @override
  String toString() =>
      '$event member=$member attempt=$attempt ${inFlight ? 'in-flight' : 'idle'}';
}

/// #46: token usage booked for one FAILED transport attempt. This is a
/// SELF-CONTAINED numeric carrier: it deliberately does NOT reference
/// [TokenUsage] (provider.dart) because this file must stay import-free at the
/// bottom of the stack. The ladder converts the real [TokenUsage] into a
/// [WireUsage] when it reports, and the metering layer converts it back.
class WireUsage {
  final int inputTokens;
  final int outputTokens;
  final int cacheCreationInputTokens;
  final int cacheReadInputTokens;

  const WireUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheCreationInputTokens = 0,
    this.cacheReadInputTokens = 0,
  });

  int get total => inputTokens + outputTokens;

  @override
  String toString() => '$inputTokens in / $outputTokens out'
      '${cacheCreationInputTokens > 0 ? ' / +$cacheCreationInputTokens write' : ''}'
      '${cacheReadInputTokens > 0 ? ' / $cacheReadInputTokens read' : ''}';
}

/// #46: usage booked for one FAILED transport attempt. Emitted through
/// an instance recorder or [Wire.reportAttemptUsage] by the retry ladder ([RetryingProvider],
/// [PooledProvider]) — the layers that swallow a before-content failure and
/// re-send the full body, so they are also the only layers that know an
/// attempt died and what it cost.
///
/// [estimated] distinguishes the two capture paths mandated by #46:
/// * false (measured) — the attempt's error carried provider-reported usage
///   (several providers include it in 429/5xx bodies or headers); those
///   counters describe reported usage, not a billing receipt;
/// * true (estimated) — an ambiguous failure carried no usage, so the ladder
///   estimates transmitted input size. This is not a lower bound on billed
///   tokens. Explicit HTTP client rejections (except 408) are not estimated.
class AttemptUsage {
  /// Which pool member / endpoint served the failed attempt ('single' when
  /// not pooled) — mirrors [WireState.member].
  final String member;

  /// 1-based attempt number within the send that failed.
  final int attempt;

  /// What the attempt cost: provider-reported when [estimated] is false,
  /// the body-size estimate when true.
  final WireUsage usage;

  /// True when [usage] is an approximation, not a provider report.
  final bool estimated;

  const AttemptUsage({
    required this.member,
    required this.attempt,
    required this.usage,
    required this.estimated,
  });

  @override
  String toString() => 'attempt#$attempt member=$member $usage'
      '${estimated ? ' (est)' : ''}';
}

/// A provider layer that owns failed-attempt accounting. An outer retry layer
/// reports to this instance rather than a process-wide meter.
abstract interface class AttemptUsageRecorder {
  void recordAttemptUsage(AttemptUsage usage);
}

abstract final class Wire {
  /// Installed by the app layer (bin/tina.dart) before any send can run.
  /// Null everywhere else — every report is then a no-op.
  static void Function(WireState state)? onWireEvent;

  /// Optional fallback for unmetered callers. Runtime meters never assign this
  /// hook: nested pool retries use the current send's scoped recorder instead.
  static void Function(AttemptUsage usage)? onAttemptUsage;

  static final Object _attemptUsageKey = Object();

  /// Bind nested asynchronous pool/transport work to its owning send. No error
  /// zone is installed, so stream errors and cancellation keep their semantics.
  static T withAttemptUsage<T>(
          void Function(AttemptUsage) recorder, T Function() body) =>
      runZoned(body, zoneValues: {_attemptUsageKey: recorder});

  static WireState? _last;
  static DateTime _inFlightSince = DateTime.now();
  static bool _inFlight = false;

  /// The most recent wire transition, or null before the first one.
  static WireState? get last => _last;

  static void report(String event,
      {String member = 'single', int attempt = 0, bool? inFlight}) {
    final f = inFlight ?? _inFlight;
    if (f && !_inFlight) _inFlightSince = DateTime.now();
    _inFlight = f;
    _last = WireState(event, member: member, attempt: attempt, inFlight: f);
    onWireEvent?.call(_last!);
  }

  /// #46: report usage booked for one failed transport attempt. Free (no-op)
  /// when no meter is installed — mirroring [report].
  static void reportAttemptUsage(AttemptUsage usage) {
    final recorder =
        Zone.current[_attemptUsageKey] as void Function(AttemptUsage)?;
    (recorder ?? onAttemptUsage)?.call(usage);
  }

  /// Elapsed time of the current (or last) in-flight request.
  static Duration get inFlightFor =>
      (_inFlight ? DateTime.now() : _last?.at ?? DateTime.now())
          .difference(_inFlightSince);

  static bool get inFlight => _inFlight;
}
