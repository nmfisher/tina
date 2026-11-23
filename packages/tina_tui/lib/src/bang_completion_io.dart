/// The `dart:io` variant: the real bang-mode completion sources.
library;

import 'completion_sources.dart';
import 'package:tina_console/tina_console.dart';

/// The `!`-mode sources for a working directory.
BangCompletion? defaultBangCompletion({required String workingDir}) =>
    BangCompletion(
      commands: const ShellCommandCompletionSource(),
      paths: BangPathCompletionSource(workingDir: workingDir),
    );
