/// The `@`-file completion seam: where `dart:io` exists the real
/// `GitFileCompletionSource` is served (it shells `git ls-files` and walks
/// directories); under the wasm compilation the picker is absent (null) —
/// spawning and the filesystem are host-owned. Routing it through the
/// `tina:process` port is the documented follow-up.
library;

export 'file_completion_unsupported.dart' if (dart.library.io) 'file_completion_io.dart';
