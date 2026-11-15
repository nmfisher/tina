/// Session persistence: the sqlite store, the persistence plugin, legacy
/// import, state compatibility, and the session-history tools.
///
/// The sqlite-touching files (store, history_reader) sit behind the
/// standard conditional seam: under the wasm compilation shape-compatible
/// stubs are served — a component has no `dart:ffi`, and the wasm session
/// store rides the injected `WasiSessionStore` seam instead. Native
/// behavior is unchanged.
library;

export 'src/store.dart';
export 'src/persistence_plugin.dart';
export 'src/legacy_import.dart';

export 'src/state_compatibility.dart';
export 'src/history_catalog.dart';
export 'src/history_tools.dart';
