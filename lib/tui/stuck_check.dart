import 'dart:async';

import 'package:tina_console/tina_console.dart';

/// Notices a frozen screen without the user having to do anything.
///
/// A freeze usually means keys are going somewhere the user cannot see (an
/// invisible permission prompt owns the keyboard) or nothing can be drawn at
/// all. A user in that state cannot type a debug command — whatever is eating
/// the keys would eat that too — so the check runs itself:
///
///  * **Keys arriving, nothing drawn:** every [interval], if keys were seen
///    since the last look but nothing has reached the terminal for
///    [stallAfter], it warns once with the editor's state snapshot.
///  * **Busy but frozen:** if the app says the agent is busy and nothing has
///    been drawn for [busyStallAfter], it warns once too — the "blocked behind
///    a prompt nobody can see" shape.
///
/// One "drawing again" line follows recovery, so the log shows where the
/// episode ended. Idle time is never reported: a chat prompt waiting for input
/// draws nothing for hours and is perfectly healthy, so a stall only counts
/// when keys are arriving or the agent claims to be working.
///
/// The lines land in the app log (`~/.tina/tina.log`) at warning level, which
/// the default configuration records — no `--verbose` needed.
class StuckCheck {
  StuckCheck({
    required this.screen,
    required this.editor,
    this.interval = const Duration(seconds: 5),
    this.stallAfter = const Duration(seconds: 30),
    this.busyStallAfter = const Duration(seconds: 60),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Screen screen;
  final LineEditor editor;

  /// How often to look.
  final Duration interval;

  /// How long the screen may go without a new presentation, while keys are
  /// arriving, before it is reported.
  final Duration stallAfter;

  /// The same, for "the agent says it is busy" — longer, because a model can
  /// legitimately think for a while without producing output.
  final Duration busyStallAfter;

  /// Where "now" comes from. Injectable so tests can step time instead of
  /// sleeping; production uses the wall clock.
  final DateTime Function() _clock;

  Timer? _timer;
  int _lastPresented = 0;
  int _lastKeys = 0;

  /// Whether any key has been seen since the last presentation. Cleared when
  /// something is drawn, so a key typed into a screen that then stops drawing
  /// is still remembered on later looks — the user may have stopped typing by
  /// the time the stall is long enough to report.
  bool _keysSincePresent = false;
  DateTime _lastPresentedAt = DateTime.now();
  bool _warned = false;

  /// How many presentations the backend has made, or null when it cannot say.
  int? get _presented => screen.presentedFrames;

  /// Begin checking. Idempotent.
  void start() {
    if (_timer != null) return;
    _lastPresented = _presented ?? 0;
    _lastKeys = editor.keyCount;
    _keysSincePresent = false;
    _lastPresentedAt = _clock();
    _warned = false;
    _timer = Timer.periodic(interval, (_) => checkNow());
  }

  /// Stop checking. Idempotent.
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Whether the check is running.
  bool get running => _timer != null;

  /// Take one look. Exposed so tests can step the check instead of waiting.
  void checkNow() {
    final presented = _presented;
    // A backend that cannot report its presentations cannot tell "nothing is
    // being drawn" from "there is nothing to draw" — stay quiet rather than
    // guess.
    if (presented == null) return;
    final keys = editor.keyCount;
    final now = _clock();

    if (presented != _lastPresented) {
      // Something was drawn: the screen is alive.
      _lastPresented = presented;
      _lastKeys = keys;
      _keysSincePresent = false;
      _lastPresentedAt = now;
      if (_warned) {
        _warned = false;
        InputLog.info('the screen is drawing again', editor.currentState());
      }
      return;
    }

    if (keys != _lastKeys) _keysSincePresent = true;
    _lastKeys = keys;
    final stalled = now.difference(_lastPresentedAt);
    final state = editor.currentState();
    final busy = state['agent_busy'] == true;

    final String? reason;
    if (_keysSincePresent && stalled >= stallAfter) {
      reason = 'keys are arriving but nothing has been drawn';
    } else if (busy && stalled >= busyStallAfter) {
      reason = 'the agent says it is busy but nothing has been drawn';
    } else {
      reason = null;
    }
    if (reason == null || _warned) return;
    _warned = true;
    InputLog.warn('$reason for ${stalled.inSeconds}s', state);
  }
}
