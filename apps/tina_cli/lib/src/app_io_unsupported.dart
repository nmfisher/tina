import 'app_io.dart';

/// The unsupported variant: every accessor throws, because a wasm
/// composition root must inject an [AppIo] before anything touches it.
final class UnsupportedAppIo implements AppIo {
  const UnsupportedAppIo();

  Never _fail() =>
      throw UnsupportedError('no AppIo injected for this platform');

  @override
  String? env(String name) => _fail();
  @override
  String get homePath => _fail();
  @override
  String get currentDirectory => _fail();
  @override
  bool exists(String path) => _fail();
  @override
  bool isDirectory(String path) => _fail();
  @override
  String? readTextIfExists(String path) => _fail();
  @override
  void createDirectory(String path, {bool recursive = false}) => _fail();
  @override
  void writeText(String path, String contents) => _fail();
  @override
  void deleteFile(String path) => _fail();
  @override
  void deleteTree(String path) => _fail();

  @override
  void rename(String from, String to) => _fail();
  @override
  String createTempDirectory(String near, String prefix) => _fail();
  @override
  String absolute(String path) => _fail();
  @override
  String canonical(String path) => _fail();
  @override
  bool get canSecureFilePermissions => false;
  @override
  void secureFilePermissions(String path) => _fail();
}

/// The no-`dart:io` [AppIo] placeholder: a wasm composition root must
/// inject an implementation ([injectedAppIo]) before anything boots.
AppIo nativeAppIo() => const UnsupportedAppIo();
