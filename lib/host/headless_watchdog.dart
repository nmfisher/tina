import 'dart:async';

/// Watchdog for silent headless hangs (#26 — Run D's silent deadlock).
///
/// The hang: an internal await (e.g. mutation lock) never resolves, so no
/// new agent-sink event is emitted, no request is in flight, and no timeout
/// fires — the process just sits. Every [AgentSink] call is also emitted on
/// the host's [AgentEventBus]; any such event resets the idle clock. When the
/// clock expires, a single diagnostic block is written to stderr and the
/// provided callback fires.
///
/// The clock is injectable (no real time in unit tests): construct with an
/// optional [nowProvider]; tests pass explicit [DateTime] values to
/// [checkIdle].
class HeadlessWatchdog {
  final Duration timeout;
  final void Function(String diagnostic) onFire;
  final DateTime Function() nowProvider;

  HeadlessWatchdog({
    required this.timeout,
    required this.onFire,
    DateTime Function()? nowProvider,
  }) : nowProvider = nowProvider ?? (() => DateTime.now());

  Timer? _timer;
  String _lastEventName = 'none';
  DateTime? _lastEventTime;
  int _eventCount = 0;
  bool _fired = false;

  /// Reset the idle clock and record the event that just happened.
  void record(String eventName) {
    _lastEventName = eventName;
    _lastEventTime = nowProvider();
    _eventCount++;
    _resetTimer();
  }

  /// Start the timer. Must be called before [record] can have any effect.
  void start() {
    _timer?.cancel();
    _timer = Timer(timeout, _fire);
  }

  /// Stop the timer and clean up. Idempotent.
  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  /// Direct clock check for tests: does the timeout expire at [now]?
  bool checkIdle(DateTime now) {
    final last = _lastEventTime;
    if (last == null) return false; // no event yet → no fire
    return now.difference(last) >= timeout && !_fired;
  }

  /// Return the last event time, for diagnostics.
  DateTime? get lastEventTime => _lastEventTime;

  /// Return the event count so far.
  int get eventCount => _eventCount;

  /// Return the last event name.
  String get lastEventName => _lastEventName;

  /// Whether the watchdog has already fired (fire-once guarantee).
  bool get fired => _fired;

  void _resetTimer() {
    _timer?.cancel();
    if (!_fired) {
      _timer = Timer(timeout, _fire);
    }
  }

  void _fire() {
    if (_fired) return;
    _fired = true;
    _timer = null;
    final last = _lastEventTime;
    final ago = last != null ? nowProvider().difference(last) : timeout;
    final block = '[watchdog] no agent activity for '
        '${timeout.inSeconds}s — aborting (last event: $_lastEventName '
        'at +${ago.inSeconds}s, total events: $_eventCount). '
        'Likely cause: an internal await that never resolves '
        '(e.g. the edit mutation lock). No stack of the parked await '
        'is retrievable from Dart.';
    onFire(block);
  }
}
