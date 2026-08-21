import 'dart:convert';
import 'dart:io' show FileSystemException;

import 'package:tina_engine/tina_engine.dart';

/// An in-memory [FileSystem] for tests. Files are stored as strings in a map;
/// directories are tracked as a set. Reads of a missing file throw
/// [FileSystemException] (matching [IoFileSystem]), so tools that pre-check
/// `fileExists` behave identically against either implementation.
///
/// Exposed fields ([files], [directories]) let tests seed state and assert on
/// post-execution results.
///
/// For tests that need to simulate binary files, use [filesBytes] instead of
/// [files] to store raw bytes directly.
class MemoryFileSystem implements FileSystem {
  final Map<String, String> files;
  final Set<String> directories;

  /// Raw bytes for files that contain non-UTF8 or binary content.
  /// Lookup: if a path exists here, its bytes are returned by [readFileBytes].
  final Map<String, List<int>> filesBytes;

  MemoryFileSystem([Map<String, String>? initial])
      : files = {...?initial},
        directories = {},
        filesBytes = {};

  /// Add a binary file (or a file whose bytes differ from the string-encoded
  /// UTF-8 representation).
  void addBinaryFile(String path, List<int> bytes) {
    filesBytes[path] = bytes;
  }

  @override
  Future<bool> fileExists(String path) async =>
      files.containsKey(path) || filesBytes.containsKey(path);

  @override
  Future<bool> directoryExists(String path) async => directories.contains(path);

  @override
  Future<List<int>> readFileBytes(String path) async {
    if (filesBytes.containsKey(path)) return filesBytes[path]!;
    _requireFile(path);
    return utf8.encode(files[path]!);
  }

  @override
  Future<String> readFileString(String path) async {
    if (filesBytes.containsKey(path)) {
      // Mirrors IoFileSystem: strict UTF-8 decode that throws on invalid
      // sequences.
      return utf8.decode(filesBytes[path]!);
    }
    _requireFile(path);
    return files[path]!;
  }

  @override
  Future<void> writeFile(String path, String content) async {
    filesBytes.remove(path);
    files[path] = content;
  }

  @override
  Future<void> createDirectory(String path, {bool recursive = false}) async {
    // `recursive` is a no-op here: there's no parent linkage to create, so any
    // path is "created" by being added to the set.
    directories.add(path);
  }

  @override
  Future<void> rename(String from, String to) async {
    if (!fileExistsSync(from)) {
      throw FileSystemException('File does not exist', from);
    }
    final bytes = filesBytes.remove(from);
    if (bytes != null) {
      filesBytes[to] = bytes;
    } else {
      files[to] = files.remove(from)!;
    }
  }

  @override
  Future<void> delete(String path) async {
    filesBytes.remove(path);
    files.remove(path);
  }

  @override
  Future<String> createTempFile({required String near}) async {
    // Deterministic, collision-free temp name for tests (no randomness needed
    // in the in-memory double). Mirrors the seam contract: lives in the same
    // "directory" as [near].
    var i = 0;
    var candidate = '$near.tmp$i';
    while (files.containsKey(candidate)) {
      i++;
      candidate = '$near.tmp$i';
    }
    return candidate;
  }

  void _requireFile(String path) {
    if (!files.containsKey(path) && !filesBytes.containsKey(path)) {
      throw FileSystemException('File does not exist', path);
    }
  }

  /// Synchronous file check for internal use (e.g., in [rename]).
  bool fileExistsSync(String path) =>
      files.containsKey(path) || filesBytes.containsKey(path);
}
