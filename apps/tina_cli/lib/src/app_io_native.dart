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

  /// Hold counts per lock path. POSIX advisory locks belong to the whole
  /// process, so a nested `lockSync` on the same file would succeed
  /// silently and the inner `unlockSync` would drop the outer hold.
  /// Counting depth here makes [lockExclusive] genuinely re-entrant:
  /// only the outermost call locks and unlocks the kernel lock.
  static final _holds = <String, int>{};

  @override
  T lockExclusive<T>(String path, T Function() body) {
    final holds = _holds[path] ?? 0;
    io.RandomAccessFile? handle;
    if (holds == 0) {
      final lock = io.File('$path.lock')..parent.createSync(recursive: true);
      handle = lock.openSync(mode: io.FileMode.append);
      handle.lockSync(io.FileLock.blockingExclusive);
    }
    _holds[path] = holds + 1;
    try {
      return body();
    } finally {
      if (holds == 0) {
        _holds.remove(path);
        handle!
          ..unlockSync()
          ..closeSync();
      } else {
        _holds[path] = holds;
      }
    }
  }

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
