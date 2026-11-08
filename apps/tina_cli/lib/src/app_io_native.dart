import 'dart:io' as io;

import 'app_io.dart';

/// The native [AppIo] over `dart:io`: thin wrappers, no added behavior.
AppIo nativeAppIo() => const NativeAppIo();

final class NativeAppIo implements AppIo {
  const NativeAppIo();

  @override
  String? env(String name) => io.Platform.environment[name];

  @override
  String get currentDirectory => io.Directory.current.path;

  @override
  String get homePath =>
      io.Platform.environment['HOME'] ?? io.Directory.systemTemp.path;

  @override
  bool exists(String path) => io.File(path).existsSync();

  @override
  bool isDirectory(String path) => io.Directory(path).existsSync();

  @override
  String? readTextIfExists(String path) {
    final file = io.File(path);
    return file.existsSync() ? file.readAsStringSync() : null;
  }

  @override
  void createDirectory(String path, {bool recursive = false}) =>
      io.Directory(path).createSync(recursive: recursive);

  @override
  void writeText(String path, String contents) =>
      io.File(path).writeAsStringSync(contents, flush: true);

  @override
  void deleteFile(String path) {
    final file = io.File(path);
    if (file.existsSync()) file.deleteSync();
  }

  @override
  void deleteTree(String path) => io.Directory(path).deleteSync(recursive: true);

  @override
  void rename(String from, String to) => io.File(from).renameSync(to);

  @override
  String createTempDirectory(String near, String prefix) =>
      io.Directory(near).createTempSync(prefix).path;

  @override
  String absolute(String path) => io.File(path).absolute.path;

  @override
  String canonical(String path) {
    final file = io.File(path);
    return file.existsSync() ? file.resolveSymbolicLinksSync() : absolute(path);
  }

  @override
  bool get canSecureFilePermissions => !io.Platform.isWindows;

  @override
  void secureFilePermissions(String path) {
    final result = io.Process.runSync('chmod', ['600', path]);
    if (result.exitCode != 0) {
      throw AppIoException('cannot secure config permissions: $path');
    }
  }
}
