/// The native channel store: sqlite via `tina_sqlite`'s versioned
/// open-or-create seam, plus the workspace-default location helper.
/// Import this only where `dart:ffi` can go; everything else imports
/// `tina_channel.dart` and receives the store through the opener seam.
library;

export 'channel_store_api.dart';
export 'src/sqlite_channel_store.dart';
export 'src/default_store.dart';
