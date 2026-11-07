import 'file_system.dart';

/// The no-`dart:io` default: a wasm composition root must inject a
/// [FileSystem]; using the default there is a wiring bug, so it fails
/// loudly instead of silently faking one.
FileSystem nativeDefaultFileSystem() => throw UnsupportedError(
    'no default FileSystem on this platform: inject one');
