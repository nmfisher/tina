import 'dart:io';

/// Env-gated paste-path audit for tin-w8dl (intermittent paste truncation +
/// swallowed Enter). Every significant hop along the input path writes one
/// line to the file named by `TINA_PASTE_AUDIT_LOG` — a file, never stderr,
/// because stderr pollutes the pane under test (repro-tool lore, tin-p8k2).
///
/// Lines are appended synchronously (`writeAsStringSync` + flush-free) so the
/// log survives a kill -9 of the TUI — the hunt loop kills the pane. Rates are
/// trivial: per native batch (~24 lines per 6k paste), per detector flush, and
/// per editor drop point, never per character. Zero overhead when the env var
/// is unset: [log] early-returns and [enabled] lets call sites skip formatting.
abstract final class PasteAudit {
  static bool get enabled => _path != null;

  /// Monotonic milliseconds since process start, stamped on every line so
  /// inter-line gaps name the delivery stalls that split a paste.
  static final Stopwatch _clock = Stopwatch();

  static final String? _path = Platform.environment['TINA_PASTE_AUDIT_LOG'];
  static String? get path => _path;

  static void log(String line) {
    final p = _path;
    if (p == null) return;
    if (!_clock.isRunning) _clock.start();
    File(p).writeAsStringSync(
      'w8dl ${_clock.elapsedMilliseconds}ms $line\n',
      mode: FileMode.append,
      flush: false,
    );
  }
}
