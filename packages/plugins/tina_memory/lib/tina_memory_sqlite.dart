/// The native memory stores: sqlite via `tina_sqlite`'s versioned
/// open-or-create seam, plus the workspace-default location helpers.
/// Import this only where `dart:ffi` can go; everything else imports
/// `tina_memory.dart` and receives stores through the opener seam.
library;

export 'memory_store_api.dart';
export 'src/sqlite_memory_store.dart';
export 'src/origin_key.dart';
export 'src/default_store_io.dart';
