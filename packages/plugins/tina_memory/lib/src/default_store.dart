/// The default memory-store location helpers behind the platform
/// conditional (the tina_channel pattern): the sqlite implementation
/// under `dart.library.io`, a throwing stub everywhere else. Import
/// THIS from composition code that must stay `dart:ffi`-free.
library;

export 'default_store_unsupported.dart'
    if (dart.library.io) 'default_store_io.dart';
