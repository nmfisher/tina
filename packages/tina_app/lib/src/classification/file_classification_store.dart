import 'dart:convert';
import 'dart:io';

import 'package:classifier/classification.dart';
import 'package:path/path.dart' as p;
import 'package:tina_engine/tina_engine.dart';

/// Legacy JSON storage, retained for migration and compatibility tests only.
/// Production indexing and browsing use SqliteClassificationStore.
/// Immutable content-addressed records with an atomically replaced manifest.
/// An advisory lock prevents competing processes from losing checkpoints.
class FileClassificationStore implements ClassificationStore {
  final String root;
  static final _writers = <String>{};
  FileClassificationStore(String projectRoot)
    : root = p.join(
        p.normalize(p.absolute(projectRoot)),
        '.tina',
        'classifications',
      );

  Future<void> _safe(String path) async {
    var current = p.dirname(root); // Also reject a linked project-local .tina.
    for (final component in [
      null,
      ...p.split(p.relative(path, from: current)),
    ]) {
      if (component != null) current = p.join(current, component);
      if (await FileSystemEntity.type(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw StateError('Classification storage cannot contain symlinks');
      }
    }
  }

  @override
  Future<T> withWriter<T>(Future<T> Function() work) async {
    final canonical = p.join(
      await Directory(p.dirname(p.dirname(root))).resolveSymbolicLinks(),
      '.tina',
      'classifications',
    );
    if (!_writers.add(canonical))
      throw StateError('Classification is already running');
    RandomAccessFile? lock;
    try {
      await _safe(p.join(root, 'records'));
      await Directory(p.join(root, 'records')).create(recursive: true);
      final lockPath = p.join(root, '.lock');
      await _safe(lockPath);
      lock = await File(lockPath).open(mode: FileMode.append);
      await lock.lock(FileLock.exclusive);
      await atomicWriteBytes(p.join(root, '.gitignore'), utf8.encode('*\n'));
      return await work();
    } finally {
      try {
        if (lock != null) {
          try {
            await lock.unlock();
          } finally {
            await lock.close();
          }
        }
      } finally {
        _writers.remove(canonical);
      }
    }
  }

  Future<Map<String, dynamic>?> _read(String path) async {
    await _safe(path);
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.notFound) return null;
    if (type != FileSystemEntityType.file)
      throw StateError('Invalid classification storage file');
    final file = File(path);
    if (await file.length() > 2 * 1024 * 1024) return null;
    final handle = await file.open();
    try {
      final bytes = await handle.read(2 * 1024 * 1024 + 1);
      if (bytes.length > 2 * 1024 * 1024) return null;
      return Map<String, dynamic>.from(jsonDecode(utf8.decode(bytes)) as Map);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    } finally {
      await handle.close();
    }
  }

  String _record(String id) {
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(id))
      throw const FormatException('Invalid record ID');
    return p.join(root, 'records', '$id.json');
  }

  @override
  Future<Map<String, dynamic>?> readManifest() =>
      _read(p.join(root, 'manifest.json'));
  @override
  Future<Map<String, dynamic>?> readRecord(String id) => _read(_record(id));
  Future<void> _write(String path, Map<String, Object?> value) async {
    await _safe(path);
    final bytes = utf8.encode(jsonEncode(value));
    if (bytes.length > 2 * 1024 * 1024)
      throw StateError('Classification record too large');
    await atomicWriteBytes(path, bytes);
  }

  @override
  Future<void> writeRecord(String id, Map<String, Object?> record) =>
      _write(_record(id), record);
  @override
  Future<void> writeManifest(Map<String, Object?> manifest) =>
      _write(p.join(root, 'manifest.json'), manifest);
}
