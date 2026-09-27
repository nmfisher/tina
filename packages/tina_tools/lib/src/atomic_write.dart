import 'file_system.dart';

/// Atomic file writes: write to a same-dir temp then rename onto the target,
/// so the target is never left half-written on a crash. Rename is atomic
/// because the temp lives in the same directory as the target. The backup
/// store of the old package is not ported — with one loop there is no
/// concurrent writer to recover from; git is the recovery path.
///
/// The caller must ensure the parent directory exists (the write tool does).
/// On rename failure the temp is deleted and the error rethrown — the target is
/// never truncated partway.
Future<void> atomicWriteFile(
  FileSystem fs,
  String path,
  String content,
) async {
  final tmp = await fs.createTempFile(near: path);
  try {
    await fs.writeFile(tmp, content);
    await fs.rename(tmp, path);
  } finally {
    try {
      await fs.delete(tmp);
    } catch (_) {
      // Cleanup must not hide the original write/rename failure.
    }
  }
}
