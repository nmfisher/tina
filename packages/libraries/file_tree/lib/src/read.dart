import 'dart:io';
import 'package:path/path.dart' as p;
import 'tree.dart';

/// Read one regular file within a byte limit. The host can validate permissions
/// and its sandbox before and after the read. Symlinks are never followed by policy.
Future<List<int>?> readFile(
  String root,
  String path, {
  int maxBytes = 128 * 1024,
  Future<void> Function(String absolutePath)? validate,
}) async {
  if (!validPath(path) || maxBytes < 1)
    throw ArgumentError('Invalid file read');
  final file = File(p.join(root, path));
  Future<void> check() async {
    await validate?.call(file.path);
    var current = root;
    for (final part in path.split('/')) {
      current = p.join(current, part);
      if (await FileSystemEntity.type(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw StateError('File path contains a symlink');
      }
    }
  }

  await check();
  final type = await FileSystemEntity.type(file.path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return null;
  if (type != FileSystemEntityType.file)
    throw StateError('Expected a regular file');
  final before = await file.stat();
  if (before.size > maxBytes) throw StateError('File exceeds read limit');
  final handle = await file.open();
  try {
    final bytes = await handle.read(maxBytes + 1);
    await check();
    final after = await file.stat();
    if (bytes.length > maxBytes ||
        bytes.length != before.size ||
        before.size != after.size ||
        before.modified != after.modified ||
        before.changed != after.changed) {
      throw StateError('File changed or exceeded read limit');
    }
    return bytes;
  } finally {
    await handle.close();
  }
}
