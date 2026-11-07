/// The file/directory operations the file-touching tools need, surfaced as a
/// seam so they can be unit-tested against an in-memory filesystem instead of
/// hitting disk. Production code uses [IoFileSystem]; tests inject a fake.
///
/// Deliberately thin: only the operations the tools actually use. Read-on-
/// missing mirrors `dart:io` (throws) so tools that pre-check [FileSystem.fileExists]
/// behave identically against either implementation.
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

/// The filesystem failure every [FileSystem] implementation throws, so
/// tools catch one type on every platform — including wasm builds, where
/// `dart:io`'s exception does not exist. [IoFileSystem] rethrows
/// `dart:io` failures as this type, message and path preserved.
final class ToolFsException implements Exception {
  const ToolFsException(this.message, [this.path, this.osError]);

  final String message;
  final String? path;
  final Object? osError;

  @override
  String toString() {
    final buffer = StringBuffer('FileSystemException: $message');
    if (path != null) buffer.write(", path = '$path'");
    if (osError != null) buffer.write(' (OS Error: $osError)');
    return buffer.toString();
  }
}
