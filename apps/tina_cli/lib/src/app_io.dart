/// The application's synchronous I/O seam.
///
/// Stage-5 (engine-on-wasm): the app layer (`tina_cli`) is not an engine
/// package and the Stage-2 ratchet does not bind it, but the headless
/// engine must compile to wasm, where `dart:io` does not exist. Every
/// `dart:io` touch in the assembly boot path goes through this interface
/// instead: the native entry injects [NativeAppIo] (the default, selected
/// by `defaultAppIo()` below), and the wasm composition root injects a
/// snapshot-backed implementation built over the preopened WASI
/// filesystem before the synchronous assembly starts.
///
/// Deliberately synchronous, like the app code it serves: the assembly
/// boot path (config load, settings stack, plugin selection) is a chain
/// of synchronous constructors callers depend on. The wasm
/// implementation pre-reads what boot needs and answers from memory.
library;

import 'package:tina_core/tina_core.dart' show EnvironmentPort;

import 'app_io_default.dart';

/// One thrown for filesystem-shaped failures, mirroring how the app
/// treated `dart:io` exceptions: callers catch generically.
final class AppIoException implements Exception {
  const AppIoException(this.message);

  final String message;

  @override
  String toString() => 'AppIoException: $message';
}

abstract interface class AppIo {
  /// The value of [name], or null when unset.
  String? env(String name);

  /// The user's home directory (`HOME` natively; the preopened config
  /// tree's root under wasm).
  String get homePath;

  /// The process's working directory.
  String get currentDirectory;

  /// Whether [path] exists (file or directory).
  bool exists(String path);

  /// Whether [path] exists and is a directory.
  bool isDirectory(String path);

  /// [path]'s contents, or null when it does not exist. Throws on other
  /// read failures, like `File.readAsStringSync`.
  String? readTextIfExists(String path);

  /// Creates [path], parents included when [recursive].
  void createDirectory(String path, {bool recursive = false});

  /// Writes [contents] to [path], atomically where the platform allows.
  void writeText(String path, String contents);

  /// Deletes the file at [path]; a no-op when it does not exist.
  void deleteFile(String path);

  /// Deletes the directory at [path] and everything under it.
  void deleteTree(String path);

  /// Renames (moves) [from] to [to].
  void rename(String from, String to);

  /// A fresh temporary directory under [near], like
  /// `Directory.createTempSync` scoped to a parent.
  String createTempDirectory(String near, String prefix);

  /// The absolute form of [path].
  String absolute(String path);

  /// The symlink-resolved form of [path] where symlinks are resolvable;
  /// implementations without symlink support return [absolute].
  String canonical(String path);

  /// Whether [secureFilePermissions] does anything on this platform.
  bool get canSecureFilePermissions;

  /// Restricts [path] to the owning user (chmod 600 on POSIX). Only
  /// called when [canSecureFilePermissions] is true.
  void secureFilePermissions(String path);
}

AppIo? _injected;

/// Injects the process-wide [AppIo] (the wasm composition root does this
/// before the assembly boots). The native entry never needs it: the
/// default below is the real thing there.
set injectedAppIo(AppIo io) => _injected = io;

/// The ambient [AppIo]: the injected one, else the platform default.
AppIo defaultAppIo() => _injected ??= platformAppIo();

/// [EnvironmentPort] over an [AppIo]: the same lookups the engine's
/// providers need, served by whichever I/O the composition root holds.
/// Natively this is exactly `IoEnvironmentPort`'s behavior.
final class AppIoEnvironmentPort implements EnvironmentPort {
  const AppIoEnvironmentPort(this._io);

  final AppIo _io;

  @override
  String? env(String name) => _io.env(name);

  @override
  String get currentDirectory => _io.currentDirectory;
}
