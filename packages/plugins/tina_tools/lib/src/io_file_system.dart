import 'dart:io';
import 'dart:math' show Random;

import 'package:path/path.dart' as p;

import 'file_system.dart';

/// [FileSystem] over real `dart:io` — thin wrappers, no added behavior.
class IoFileSystem implements FileSystem {
  const IoFileSystem();

  @override
  Future<bool> fileExists(String path) => File(path).exists();

  @override
  Future<bool> directoryExists(String path) => Directory(path).exists();

  @override
  Future<List<int>> readFileBytes(String path) async =>
      await File(path).readAsBytes();

  @override
  Future<String> readFileString(String path) => File(path).readAsString();

  @override
  Future<void> writeFile(String path, String content) =>
      File(path).writeAsString(content);

  @override
  Future<void> createDirectory(String path, {bool recursive = false}) =>
      Directory(path).create(recursive: recursive);

  @override
  Future<void> rename(String from, String to) async {
    await File(from).rename(to);
  }

  @override
  Future<void> delete(String path) async {
    final f = File(path);
    if (await f.exists()) await f.delete();
  }

  @override
  Future<String> createTempFile({required String near}) async {
    final dir = p.dirname(near);
    // Emulate the removed `File.createTempFile` with a random suffix so the
    // temp name is unpredictable (an adversary who guesses it could race the
    // rename). The temp lives in the *same* dir as the target so the eventual
    // rename is on one filesystem → atomic.
    final base = p.basenameWithoutExtension(near);
    for (var attempt = 0; attempt < 10; attempt++) {
      final name = '.tina-write-$base-$attempt-${_randomSuffix()}';
      final candidate = dir == '.' ? name : p.join(dir, name);
      if (!await File(candidate).exists()) return candidate;
    }
    return '.tina-write-$base-${_randomSuffix()}';
  }
}

/// A short random hex suffix for temp-file names.
String _randomSuffix() {
  final r = Random();
  return r.nextInt(0x7fffffff).toRadixString(16);
}
