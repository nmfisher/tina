import '../input_event.dart';

/// Detects bracketed-paste-like bursts in a key stream that has *no* paste
/// markers — notably the notcurses backend, where `ESC[200~`/`ESC[201~` are
/// swallowed by notcurses' own input parser (confirmed by the dart_notcurses
/// paste spike: a paste produces zero boundary events). Paste detection there
/// relies on **temporal clustering**: a terminal paste flushes the whole
/// clipboard to the pty in microseconds, so consecutive events arrive with
/// inter-event gaps of ~15–30µs, whereas typing has ≥50ms between keystrokes
/// (human max ~10cps). The regimes are separated by ~1000×, so a modest join
/// window cleanly distinguishes them.
///
/// This is a pure, time-parameterized state machine — no I/O, no notcurses
/// dependency — so it can be unit-tested directly. The notcurses input
/// backend feeds it translated [InputEvent]s with a monotonic timestamp;
/// [flush] (or a gap exceeding [joinWindow]) drains the pending buffer:
///   - ≥ [minPasteChars] buffered chars → a single [PasteInput] (newlines and
///     tabs folded in from mid-burst Enter/Tab events, so a pasted newline
///     does NOT submit the line mid-paste — the core bug this fixes).
///   - otherwise → the individual events, emitted as before (a single fast
///     key, or a short burst below threshold, is treated as typing).
///
/// The detector is single-threaded and not re-entrant: callers must serialize
/// [add] / [flush] / [expire].
class PasteBurstDetector {
  /// Two consecutive events closer than this in time are considered part of
  /// the same burst. Must sit above the paste-event cluster (~0.1ms) and below
  /// the smallest typing gap (~50ms). The spike measured paste gaps ≤0.13ms
  /// and typing/reaction gaps ≥128ms, so 30ms is ~240× above the cluster and
  /// ~4× below typing — a safe middle.
  final Duration joinWindow;

  /// Minimum buffered character count for a flushed burst to be treated as a
  /// paste. Below this, the events are emitted individually (so a single
  /// keystroke, or two keys that happened to land close, aren't mistaken for
  /// a paste). Set high enough that fast typing rarely sustains it.
  final int minPasteChars;

  // Pending events since the last flush. Non-empty only while a burst is open.
  final List<_TimedEvent> _pending = [];
  // Total characters accumulated in the current burst (sum of _TimedEvent.charCount
  // for char/Enter/Tab entries — Enter/Tab count as 1 char: \n / \t).
  int _burstChars = 0;

  PasteBurstDetector({
    this.joinWindow = const Duration(milliseconds: 30),
    this.minPasteChars = 8,
  });

  /// Feed one translated event with a monotonic timestamp (microseconds since
  /// an arbitrary epoch — only deltas matter). Returns the events to emit
  /// now: if the gap since the previous event exceeds [joinWindow], the
  /// pending burst is flushed first, then `event` starts a fresh burst and is
  /// buffered (emitted on the next flush). Otherwise `event` is appended to
  /// the open burst and nothing is emitted yet (the burst is still forming).
  ///
  /// Callers MUST also call [expire] periodically (e.g. each poll tick) so a
  /// burst that has stopped forming is flushed after [joinWindow] elapses —
  /// otherwise the last burst's events sit buffered until the next keypress.
  List<InputEvent> add(InputEvent event, int nowMicros) {
    final emitted = <InputEvent>[];
    if (_pending.isNotEmpty) {
      final last = _pending.last;
      if (nowMicros - last.timeMicros > joinWindow.inMicroseconds) {
        emitted.addAll(_drain());
      }
    }
    _append(event, nowMicros);
    return emitted;
  }

  /// Drop the oldest pending events whose gap to `nowMicros` exceeds the join
  /// window — i.e. flush a burst that has stopped forming. Called each poll
  /// tick so a finished paste is emitted promptly even if no new key arrives.
  List<InputEvent> expire(int nowMicros) {
    if (_pending.isEmpty) return const [];
    final last = _pending.last;
    if (nowMicros - last.timeMicros > joinWindow.inMicroseconds) {
      return _drain();
    }
    return const [];
  }

  /// Flush and discard any pending burst (e.g. on dispose). Returns any
  /// not-yet-emitted events.
  List<InputEvent> flush() =>
      _pending.isEmpty ? const [] : _drain();

  bool get hasPending => _pending.isNotEmpty;

  void _append(InputEvent event, int nowMicros) {
    final ch = _charCount(event);
    _pending.add(_TimedEvent(event, nowMicros, ch));
    _burstChars += ch;
  }

  List<InputEvent> _drain() {
    if (_pending.isEmpty) return const [];
    final events = <InputEvent>[];
    if (_burstChars >= minPasteChars) {
      // Join into one paste. Enter→\n, Tab→\t, CharInput→its text, so a pasted
      // multi-line block survives with newlines intact and doesn't submit
      // mid-paste.
      final buf = StringBuffer();
      for (final e in _pending) {
        buf.write(_pasteText(e.event));
      }
      events.add(PasteInput(buf.toString()));
    } else {
      for (final e in _pending) {
        events.add(e.event);
      }
    }
    _pending.clear();
    _burstChars = 0;
    return events;
  }

  /// Characters this event contributes to a paste's char count and joined
  /// text. Enter and Tab count as one char each (\n / \t) — a paste of N
  /// lines still has N chars of newline, so it clears [minPasteChars] and,
  /// crucially, the newlines are preserved in the joined [PasteInput] rather
  /// than emitted as submit/Tab events.
  int _charCount(InputEvent e) {
    if (e is CharInput) return e.text.length;
    if (e is ControlKey) {
      if (e.code == ControlCode.enter) return 1; // \n
      if (e.code == ControlCode.tab) return 1; // \t
      return 0;
    }
    return 0;
  }

  String _pasteText(InputEvent e) {
    if (e is CharInput) return e.text;
    if (e is ControlKey) {
      if (e.code == ControlCode.enter) return '\n';
      if (e.code == ControlCode.tab) return '\t';
    }
    // Non-text events inside a burst (arrows, function keys) are rare in a
    // paste but possible; preserve nothing rather than emit junk. They don't
    // count toward [_burstChars] either, so they can't inflate a short burst
    // into a paste.
    return '';
  }
}

class _TimedEvent {
  final InputEvent event;
  final int timeMicros;
  final int charCount;
  _TimedEvent(this.event, this.timeMicros, this.charCount);
}
