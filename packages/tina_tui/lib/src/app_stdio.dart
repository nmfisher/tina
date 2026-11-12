/// The app's stdio seam (the stdio pattern again): native gets raw
/// process stdin for the backend-owning paths; wasm gets the throwing
/// [LiveStdio] shape — the guest injects its WASI Stdio instead.
library;

export 'app_stdio_unsupported.dart' if (dart.library.io) 'app_stdio_io.dart';
