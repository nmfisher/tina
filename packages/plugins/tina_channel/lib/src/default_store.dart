/// Opens the workspace's default channel store. Natively that is the
/// sqlite implementation at `.tina/channel.db` (parents created);
/// platforms without `dart:io` throw — a wasm composition root
/// injects its own implementation through the opener seam instead.
library;

export 'default_store_unsupported.dart'
    if (dart.library.io) 'default_store_io.dart';
