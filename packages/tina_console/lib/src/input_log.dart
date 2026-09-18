import 'dart:io';

import 'package:logging/logging.dart';

import 'input_event.dart';

/// Where a keypress ended up.
///
/// Every branch of the editor's dispatch returns one of these instead of a bare
/// `return`, so a key that does nothing visible can name who took it. The value
/// is written by [InputLog.key].
enum KeyHandledBy {
  /// Ctrl+C — the quit flow, handled ahead of everything else.
  quit,

  /// An overlay, dialog, or completion picker took it.
  modal,

  /// The menu bar took it.
  menu,

  /// A panel-switching / cycling key.
  focusRing,

  /// A side panel took it.
  panel,

  /// An app-wide shortcut: panel maximize, raw-markdown view, permission-mode
  /// cycling.
  appShortcut,

  /// A prompt is waiting for a key — a permission question, a human gate, or an
  /// overlay's own prompt. Typing here answers the prompt, so it never reaches
  /// the chat input.
  openPrompt,

  /// A paste parked until an open prompt is answered.
  heldPaste,

  /// Part of a paste, held behind the short burst window after a prompt closes.
  pasteOverflow,

  /// Typed while the agent is busy: goes to the queued-message line.
  queuedInput,

  /// Reached the chat input — the normal, visible case.
  chatBox,

  /// Dropped: nothing handled it. This is the freeze signature.
  nobody,
}

/// Writes where each key went, so a freeze can be read back from the log later.
///
/// Two tiers:
///
///  * **Always on, rare:** a key that nobody handled is a bug, so it is logged
///    at warning level (through `package:logging`, i.e. the app's
///    `~/.tina/tina.log`) once per run of dropped keys, plus one line when keys
///    start being handled again.
///  * **Off by default:** a per-key trail, enabled with
///    `TINA_INPUT_TRACE=<file>`. Coalesced to at most [maxLinesPerSecond] full
///    lines per second so a fast typist cannot flood it.
///
/// Mirrors the paste audit's rules: a debug log writes synchronously so it
/// survives a kill, and never writes to stderr (which would corrupt the
/// alternate screen).
abstract final class InputLog {
  static final Logger _log = Logger('tina_console.input');
  static String? _tracePath = Platform.environment['TINA_INPUT_TRACE'];
  static final Stopwatch _clock = Stopwatch()..start();

  /// Full trail lines written per one-second window before coalescing.
  static const int maxLinesPerSecond = 20;

  /// Whether the per-key trail is being written.
  static bool get tracing => _tracePath != null;

  /// The trail file, when tracing is on. Used by tests.
  static String? get tracePath => _tracePath;

  static int _droppedRun = 0;
  static int _windowCount = 0;
  static int _windowStartMs = 0;

  /// Test-only escape hatch so a test can point the trail at a temp file (or
  /// turn it off) without spawning a process with the env var set. Mirrors
  /// [InputLatency.forceEnable].
  static void setTraceFile(String? path) => _tracePath = path;

  /// Test-only: clear the run/coalescing counters so each test starts clean.
  static void reset() {
    _droppedRun = 0;
    _windowCount = 0;
    _windowStartMs = 0;
  }

  /// Record where [event] went. [state] builds the snapshot from
  /// `LineEditor.currentState()`; it is only called when something will
  /// actually be written, so a normal keystroke costs nothing.
  static void key(
    InputEvent event,
    KeyHandledBy who,
    Map<String, Object?> Function() state,
  ) {
    Map<String, Object?>? built;
    Map<String, Object?> snapshot() => built ??= state();

    if (who == KeyHandledBy.nobody) {
      if (_droppedRun == 0) {
        _log.warning('key dropped - nothing handled it: '
            'key=${describeKey(event)} ${format(snapshot())}');
      }
      _droppedRun++;
      if (_droppedRun == 20) {
        _log.warning('keys still being dropped - 20 in a row and counting');
      }
    } else if (_droppedRun > 0) {
      _log.info('keys are being handled again '
          '($_droppedRun were dropped before this one)');
      _droppedRun = 0;
    }
    if (_tracePath == null) return;
    _trail(describeKey(event), who.name, snapshot());
  }

  /// Record a condition worth noticing (a stuck screen, an unclosed frame).
  static void warn(String message, Map<String, Object?> state) {
    _log.warning('$message ${format(state)}');
    _append('warn  $message ${format(state)}');
  }

  /// Record the end of a condition that was warned about.
  static void info(String message, Map<String, Object?> state) {
    _log.info('$message ${format(state)}');
    _append('ok    $message ${format(state)}');
  }

  /// A short, log-safe description of [event]. Character keys show the
  /// character; pastes show only their length, never their text.
  static String describeKey(InputEvent event) => switch (event) {
        CharInput(:final text) =>
          'char(${text.length == 1 ? text : '${text.length} chars'})',
        PasteInput(:final text) => 'paste(${text.length})',
        ControlKey(:final code) => 'ctrl(${code.name})',
        ArrowKey(:final direction) => 'arrow(${direction.name})',
        EditingKey(:final action) => 'edit(${action.name})',
        AltKey(:final letter) => 'alt(${String.fromCharCode(letter)})',
        FunctionKey(:final code) => 'fn(${code.name})',
        EscapeKey() => 'esc',
        ScrollEvent(:final up) => 'scroll(${up ? 'up' : 'down'})',
        UnknownEscape() => 'unknown-escape',
      };

  /// [state] as one `name=value name=value` line. Null values are skipped, so a
  /// field only appears when it is meaningful.
  static String format(Map<String, Object?> state) {
    final line = StringBuffer();
    for (final entry in state.entries) {
      final value = entry.value;
      if (value == null) continue;
      if (line.isNotEmpty) line.write(' ');
      line.write('${entry.key}=$value');
    }
    return line.toString();
  }

  /// Append one line to the per-key trail, coalescing past
  /// [maxLinesPerSecond] in a window.
  static void _trail(String key, String who, Map<String, Object?> state) {
    if (_tracePath == null) return;
    final ms = _clock.elapsedMilliseconds;
    if (ms - _windowStartMs >= 1000) {
      _windowStartMs = ms;
      _windowCount = 0;
    }
    _windowCount++;
    if (_windowCount > maxLinesPerSecond) {
      if (_windowCount == maxLinesPerSecond + 1) {
        _append('key   (more keys this second suppressed)');
      }
      return;
    }
    _append('key   who=$who key=$key ${format(state)}');
  }

  static void _append(String line) {
    final path = _tracePath;
    if (path == null) return;
    final ms = _clock.elapsedMilliseconds;
    try {
      File(path).writeAsStringSync(
        'tina-input ${ms}ms $line\n',
        mode: FileMode.append,
        flush: true,
      );
    } catch (_) {
      // A debug log must never break the TUI.
    }
  }
}
