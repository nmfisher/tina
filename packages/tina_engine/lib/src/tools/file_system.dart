import 'dart:io';

import 'dart:math' show Random;

import 'package:path/path.dart' as p;

/// The file/directory operations the file-touching tools need, surfaced as a
/// seam so they can be unit-tested against an in-memory filesystem instead of
/// hitting disk. Production code uses [IoFileSystem]; tests inject a fake.
///
/// Deliberately thin: only the operations [ReadTool], [WriteTool], and
/// [EditTool] actually use. Read-on-missing mirrors `dart:io` (throws) so tools
/// that pre-check [fileExists] behave identically against either implementation.
abstract class FileSystem {
  Future<bool> fileExists(String path);
  Future<bool> directoryExists(String path);
  Future<List<int>> readFileBytes(String path);
  Future<String> readFileString(String path);
  Future<void> writeFile(String path, String content);
  Future<void> createDirectory(String path, {bool recursive = false});

  /// Atomically moves [from] to [to]. Used by atomic-write paths so a write can
  /// land as a single rename rather than a truncate-then-write that leaves a
  /// half-written file on a crash.
  Future<void> rename(String from, String to);

  /// Deletes the file at [path]. Used to clean up a temp file after a failed
  /// atomic rename.
  Future<void> delete(String path);

  /// Creates a temporary file in the same directory as [near], with a
  /// crypto-random name, and returns its path. The caller writes to it then
  /// [rename]s it onto the final target.
  Future<String> createTempFile({required String near});
}

/// [FileSystem] over real `dart:io` — thin wrappers, no added behavior. Tools
/// get this by default when constructed with no argument, so existing callers
/// are unchanged.
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
    // `File.createTempFile` was removed in recent SDKs; emulate it with a
    // crypto-random suffix so the temp name is unpredictable (an adversary who
    // guesses it could race the rename). The temp lives in the *same* dir as the
    // target so the eventual rename is on one filesystem → atomic.
    final base = p.basenameWithoutExtension(near);
    for (var attempt = 0; attempt < 10; attempt++) {
      final name = '.tina-write-$base-$attempt-${_randomSuffix()}';
      final candidate = dir == '.' ? name : p.join(dir, name);
      if (!await File(candidate).exists()) return candidate;
    }
    return '.tina-write-$base-${_randomSuffix()}';
  }
}

/// A short random hex suffix for temp-file names. Isolated so tests can stub it
/// if they ever need deterministic names.
String _randomSuffix() {
  final r = Random();
  return r.nextInt(0x7fffffff).toRadixString(16);
}
