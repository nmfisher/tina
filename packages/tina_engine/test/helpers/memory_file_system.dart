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
class MemoryFileSystem implements FileSystem {
  final Map<String, String> files;
  final Set<String> directories;

  MemoryFileSystem([Map<String, String>? initial])
      : files = {...?initial},
        directories = {};

  @override
  Future<bool> fileExists(String path) async => files.containsKey(path);

  @override
  Future<bool> directoryExists(String path) async => directories.contains(path);

  @override
  Future<List<int>> readFileBytes(String path) async {
    _requireFile(path);
    return utf8.encode(files[path]!);
  }

  @override
  Future<String> readFileString(String path) async {
    _requireFile(path);
    return files[path]!;
  }

  @override
  Future<void> writeFile(String path, String content) async {
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
    if (!files.containsKey(from)) {
      throw FileSystemException('File does not exist', from);
    }
    files[to] = files[from]!;
    files.remove(from);
  }

  @override
  Future<void> delete(String path) async {
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
    if (!files.containsKey(path)) {
      throw FileSystemException('File does not exist', path);
    }
  }
}
