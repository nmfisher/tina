/// The no-`dart:io` variant (wasm compilation): no `@` file completion —
/// spawning and the filesystem are host-owned. The editor's picker stays
/// armed for command completion only.
library;

import 'package:fuzzy_ranker/fuzzy_ranker.dart';

/// No file completion under wasm; `null` leaves the picker to commands.
CompletionProvider? defaultFileCompletion({required String workingDir}) =>
    null;
