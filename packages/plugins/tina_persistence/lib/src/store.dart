/// The sqlite-backed session store, behind the standard conditional seam:
/// where `dart:io` exists the real store is served; under the wasm
/// compilation a shape-compatible stub is served (a component has no
/// `dart:ffi`; the wasm session store is the injected `WasiSessionStore`).
/// Native behavior unchanged.
library;

export 'store_unsupported.dart' if (dart.library.io) 'store_io.dart';
