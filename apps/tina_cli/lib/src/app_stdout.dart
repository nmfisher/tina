/// Where the app's bare stdout lines go (the session-listing writer).
/// Native: the process's stdout. A wasm composition root injects its own
/// sink (the WASI stdout the host relays) before anything prints.
library;

import 'app_stdout_unsupported.dart' if (dart.library.io) 'app_stdout_io.dart';

/// The injected stdout sink, when a composition root set one; the
/// platform default otherwise.
void Function(String line)? injectedStdoutSink;

/// Writes one line to the app's stdout.
void appStdoutWriteln(String line) =>
    (injectedStdoutSink ?? nativeAppStdoutWriteln)(line);
