/// The native-only barrel for the FFI terminal probe. The shared
/// `tina_console.dart` barrel deliberately does NOT export
/// `notcurses_probe.dart`: it reads `dart:ffi` + `dart:io`, which would
/// drag both into every wasm closure that imports the toolkit. Native
/// tooling that wants the probe imports this barrel instead.
library;

export 'src/backend/notcurses_probe.dart';
