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
/// The field signature of the reported freeze (2026-09-24 log, three separate
/// sessions):
///
/// ```
/// keys are arriving but nothing has been drawn for 69s chat_prompt_open=true
/// input_row_hidden=false focused_panel=PanelFrame frames_open=0 agent_busy=false
/// ```
///
/// A *visible* chat prompt with a panel focused, nothing drawing: keys were
/// going to a surface the user was not typing into, and no keystroke reached
/// the editor that would have requested a repaint. It is not a backend frame
/// leak — `frames_open=0`. The editor-side half of that fix is that a visible
/// prompt row outranks a focused panel's key claim; this check covers the
/// residue, where damage bookkeeping can still leave the screen stale once the
/// keys are flowing again.
///
/// The lines land in the app log (`~/.tina/tina.log`) at warning level, which
/// the default configuration records — no `--verbose` needed.
class StuckCheck {
  StuckCheck({
    required this.screen,
    required this.editor,
    this.heal = true,
    this.interval = const Duration(seconds: 5),
    this.stallAfter = const Duration(seconds: 30),
    this.busyStallAfter = const Duration(seconds: 60),
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final Screen screen;
  final LineEditor editor;

  /// Whether a reported stall is actively healed, not just logged. When true
  /// the first warning triggers [Screen.refresh] — the same full re-emission a
  /// terminal resize runs. The warning is the diagnostic; the refresh is what
  /// ends the episode, because a stall is self-sustaining once the damage grid's
  /// idea of the screen diverges from the real terminal: every redraw then
  /// computes "no change" and the screen sits stale until something forces a
  /// full re-emission (which is why resizing the terminal always appeared to
  /// fix it). The underlying key routing is fixed at the source, so this is the
  /// belt to that pair of braces.
  ///
  /// Defaults to true, but production runs it **off**: `tui_coordinator`
  /// constructs the check with `heal: false` so a stall is observed rather than
  /// patched, and a false positive costs a log line instead of an unexplained
  /// repaint. Tests that exercise the detection alone also pass `heal: false`;
  /// pass `heal: true` to exercise the repair.
  final bool heal;

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
    // The message must not claim a repaint that is not coming: with heal:false
    // the log is the only product, and a line promising "forcing a full
    // repaint" would send a reader looking for a recovery that never happens.
    final suffix = heal ? '; forcing a full repaint' : '';
    InputLog.warn('$reason for ${stalled.inSeconds}s$suffix', state);
    if (!heal) return;
    // The heal: re-emit the retained frame in full, bypassing the damage
    // tracking that is now lying about what the terminal shows. _lastPresented
    // is deliberately NOT updated here: if the backend re-presented (a full
    // re-rasterize bumps its counter), the next look sees the change and logs
    // the usual "drawing again" recovery; if the refresh did not present
    // (no-op or already in sync), the stall simply continues without a second
    // warning — no false cure is claimed either way.
    screen.refresh();
  }
}
