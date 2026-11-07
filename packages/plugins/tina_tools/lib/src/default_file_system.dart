import 'file_system.dart';
import 'default_file_system_unsupported.dart'
    if (dart.library.io) 'default_file_system_io.dart';

export 'file_system.dart';

/// The platform default [FileSystem]: the real `dart:io` one where that
/// library exists; nothing under wasm (a wasm composition root injects
/// the implementation — the default is a loud failure, not a silent
/// fake).
FileSystem defaultFileSystem() => nativeDefaultFileSystem();
