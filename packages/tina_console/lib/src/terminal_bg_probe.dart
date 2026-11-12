/// The terminal-background probe seam: where `dart:io` exists,
/// `terminal_bg_io.dart` serves the platform heuristic and the real OSC-11
/// query; under the wasm compilation `terminal_bg_unsupported.dart`
/// serves the same shapes — the host owns the tty bytes, so there is no
/// round-trip and the background resolves unknown.
library;

export 'terminal_bg_unsupported.dart' if (dart.library.io) 'terminal_bg_io.dart';
