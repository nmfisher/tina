/// The `!`-mode completion seam: where `dart:io` exists the real sources
/// are served (a PATH scan for command names, the git-aware file source for
/// argument paths); under the wasm compilation this is null — spawning and
/// the filesystem are host-owned, and routing them through the
/// `tina:process` port is the documented follow-up (separate task). The
/// `@` file-completion seam (`file_completion.dart`) is unchanged.
library;

export 'bang_completion_unsupported.dart'
    if (dart.library.io) 'bang_completion_io.dart';
