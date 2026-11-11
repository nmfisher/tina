/// Optional native terminal backend. Pair it with its own input backend.
///
/// Conditional barrel (the stdio seam pattern): where `dart:io` exists the
/// real FFI backend is served; under the wasm compilation a shape-compatible
/// stub is served so app-level `is NotcursesBackend` checks compile and are
/// simply always false — the wasm guest runs the ANSI backend only.
library;

export 'notcurses_unsupported.dart' if (dart.library.io) 'notcurses_native.dart';
