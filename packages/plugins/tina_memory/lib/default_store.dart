/// The conditional memory-store seam for composition code whose graph
/// must compile off the VM (the channel default_store pattern): the
/// throwing stub under wasm, the sqlite openers natively.
library;

export 'src/default_store_unsupported.dart'
    if (dart.library.io) 'src/default_store_io.dart';
