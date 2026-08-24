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
/// This library deliberately imports nothing — it sits at the bottom of the
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

abstract final class Wire {
  /// Installed by the app layer (bin/tina.dart) before any send can run.
  /// Null everywhere else — every report is then a no-op.
  static void Function(WireState state)? onWireEvent;

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
    _last = WireState(event,
        member: member, attempt: attempt, inFlight: f);
    onWireEvent?.call(_last!);
  }

  /// Elapsed time of the current (or last) in-flight request.
  static Duration get inFlightFor =>
      (_inFlight ? DateTime.now() : _last?.at ?? DateTime.now())
          .difference(_inFlightSince);

  static bool get inFlight => _inFlight;
}
