/// Narrow interface over stdin/stdout and signal watching, with the
/// production implementation selected per platform.
///
/// Conditional import (the persistence-seam pattern): where `dart:io`
/// exists, `stdio_io.dart` serves today's [LiveStdio] and re-exports
/// `dart:io`'s `ProcessSignal` unchanged; under the wasm compilation
/// (`dart:io` does not exist) `stdio_unsupported.dart` serves the same
/// interface with a stub signal type — the composition root injects the
/// WASI-backed implementation, exactly where the native entry injects
/// [LiveStdio].
library;

export 'stdio_unsupported.dart' if (dart.library.io) 'stdio_io.dart';
