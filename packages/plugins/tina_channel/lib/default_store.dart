/// The default channel store behind the platform conditional: the
/// sqlite implementation under `dart.library.io`, a throwing stub
/// everywhere else. Import THIS from composition code that must stay
/// `dart:ffi`-free — the plugin catalog, whose graph also compiles to
/// Wasm. `tina_channel_sqlite.dart` remains the native-only entry for
/// code that never compiles off the VM (the CLI, tests).
library;

export 'src/default_store.dart';
