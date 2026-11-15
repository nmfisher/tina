/// The `dart:io` variant: the real git-aware completion source.
library;

import 'completion_sources.dart';
import 'package:fuzzy_ranker/fuzzy_ranker.dart';

/// The default file-completion provider for a working directory.
CompletionProvider? defaultFileCompletion({required String workingDir}) =>
    GitFileCompletionSource(workingDir: workingDir);
