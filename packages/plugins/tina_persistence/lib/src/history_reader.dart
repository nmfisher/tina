/// The sqlite-backed session-history reader, behind the standard
/// conditional seam (same rationale as `store.dart`): the wasm compilation
/// serves a shape-compatible stub; native behavior unchanged.
library;

export 'history_reader_unsupported.dart'
    if (dart.library.io) 'history_reader_io.dart';
