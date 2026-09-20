import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'exploration_cache.dart';

/// One atomic JSON file per content-addressed record. Readers never see partial
/// writes; concurrent processes may safely replace the same deterministic key.
class FileExplorationCache implements ExplorationCache {
  final String projectRoot;
  final int maxRecordBytes;
  FileExplorationCache(
    this.projectRoot, {
    this.maxRecordBytes = 8 * 1024 * 1024,
  });

  Future<Directory?> _directory({required bool create}) async {
    var root = await Directory(projectRoot).resolveSymbolicLinks();
    for (final component in ['.tina', 'exploration']) {
      root = p.join(root, component);
      var type = await FileSystemEntity.type(root, followLinks: false);
      if (type == FileSystemEntityType.notFound && create) {
        await Directory(root).create();
        type = await FileSystemEntity.type(root, followLinks: false);
      }
      if (type != FileSystemEntityType.directory) return null;
    }
    return Directory(root);
  }

  void _validateKey(String key) {
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(key))
      throw ArgumentError('Invalid cache key');
  }

  @override
  Future<Map<String, dynamic>?> read(String key) async {
    _validateKey(key);
    try {
      final dir = await _directory(create: false);
      if (dir == null) return null;
      final file = File(p.join(dir.path, '$key.json'));
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
              FileSystemEntityType.file ||
          await file.length() > maxRecordBytes)
        return null;
      final bytes = await file
          .openRead(0, maxRecordBytes + 1)
          .fold<List<int>>([], (a, b) => a..addAll(b));
      if (bytes.length > maxRecordBytes) return null;
      return Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> write(String key, Map<String, dynamic> record) async {
    _validateKey(key);
    Directory? temporary;
    try {
      final bytes = utf8.encode(jsonEncode(record));
      if (bytes.length > maxRecordBytes) return;
      final dir = await _directory(create: true);
      if (dir == null) return;
      temporary = await dir.createTemp('.write-');
      final ignore = File(p.join(dir.path, '.gitignore'));
      if (await FileSystemEntity.type(ignore.path, followLinks: false) ==
          FileSystemEntityType.notFound) {
        final stagedIgnore = File(p.join(temporary.path, 'ignore'));
        await stagedIgnore.writeAsString('*\n');
        await stagedIgnore.rename(ignore.path);
      }
      final file = File(p.join(temporary.path, 'record.json'));
      await file.writeAsBytes(bytes, flush: true);
      await file.rename(p.join(dir.path, '$key.json'));
    } catch (_) {
      /* Read-only or unavailable storage simply disables reuse. */
    } finally {
      if (temporary != null) {
        try {
          await temporary.delete(recursive: true);
        } catch (_) {}
      }
    }
  }
}
