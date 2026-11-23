/// The wasm variant: no bang-mode completion. PATH scanning and file
/// listing need `dart:io`; serving them through the `tina:process` port is
/// the documented follow-up (separate task).
library;

import 'package:tina_console/tina_console.dart';

/// Always null under this compilation.
BangCompletion? defaultBangCompletion({required String workingDir}) => null;
