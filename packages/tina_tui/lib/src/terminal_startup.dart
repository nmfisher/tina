/// The terminal-startup seam (the stdio/platform_env pattern): where
/// `dart:io` exists, `terminal_startup_io.dart` serves the FFI termios
/// snapshot unchanged; under the wasm compilation `terminal_startup_unsupported.dart`
/// serves the same public shape — there the HOST owns the terminal (raw mode
/// before the stdin pump, Drop-guard restoration), so a guest-side
/// snapshot-and-restore is meaningless and `capture` is refused loudly.
library;

export 'terminal_startup_unsupported.dart'
    if (dart.library.io) 'terminal_startup_io.dart';
