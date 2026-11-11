/// The `dart:io` variant of the app stdio: raw single-subscription process
/// stdin (the native backend owns its input and reads the process stream
/// directly, bypassing the broadcast relay). Selected by `app_stdio.dart`
/// where `dart:io` exists.
library;

import 'dart:io' as io;

import 'package:tina_console/src/stdio_io.dart';

final class AppStdio extends LiveStdio {
  const AppStdio();

  @override
  Stream<List<int>> get stdin => io.stdin;
}
