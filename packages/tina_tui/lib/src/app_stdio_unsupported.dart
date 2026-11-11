/// The no-`dart:io` variant of the app stdio (wasm compilation): never
/// constructed — the composition root injects its WASI-backed Stdio, and
/// the native-only paths that build [AppStdio] are unreachable under wasm.
library;

import 'package:tina_console/src/stdio_unsupported.dart';

final class AppStdio extends LiveStdio {
  const AppStdio();
}
