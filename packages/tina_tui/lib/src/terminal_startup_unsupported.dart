/// The no-`dart:io` variant of the terminal-startup seam (wasm
/// compilation): same public shape as `terminal_startup_io.dart`, but
/// capture is refused loudly — the HOST owns the terminal under wasm (raw
/// mode before the stdin pump, Drop-guard restoration on every exit path),
/// so a guest-side snapshot-and-restore is meaningless there.
library;

/// Preserve stdin before native initialization — meaningless under wasm.
final class TerminalStartupSnapshot {
  TerminalStartupSnapshot._();

  static TerminalStartupSnapshot capture() => throw UnsupportedError(
      'the host owns the terminal under wasm: no guest-side startup snapshot');

  void restore() => throw UnsupportedError(
      'the host owns the terminal under wasm: no guest-side startup snapshot');

  void dispose() {}
}
