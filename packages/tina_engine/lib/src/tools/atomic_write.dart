import 'dart:convert';
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'file_system.dart';

/// Atomic file writes with a centralized, size-bounded backup store.
///
/// Two pieces, both taking an explicit [FileSystem] so they run against
/// [MemoryFileSystem] in tests (no real-disk hits):
/// - [atomicWriteFile] — write to a same-dir temp then `rename` onto the target,
///   so the target is never left half-written on a crash. Rename is atomic
///   because the temp lives in the same directory as the target.
/// - [BackupStore] — copies an existing file to a single hidden tree under a
///   store dir before it's overwritten, with a global LRU cap, a per-file size
///   cap, and a total-byte ceiling so backups can't fill the disk.

final _log = Logger('tina.atomic_write');

/// Hard-coded backups cap. LRU-evicted before each new backup once this many
/// exist. No config surface by design.
const int kMaxBackups = 50;

/// Files larger than this are not backed up (a 50MB source is cheaper to version
/// in git than to shadow 50 times). The write still proceeds.
const int kMaxBackupFileBytes = 50 * 1024 * 1024;

/// Total bytes backups are allowed to occupy before oldest entries are evicted
/// to make room. Guards the disk on the external-volume setup this user runs.
const int kMaxBackupTotalBytes = 500 * 1024 * 1024;

/// Write [content] to [path] atomically via a same-dir temp + rename.
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
  await fs.writeFile(tmp, content);
  try {
    await fs.rename(tmp, path);
  } catch (e) {
    // Rename failed (shouldn't happen — same dir → same filesystem). Clean up
    // the temp so we don't litter, and surface the error; the target is intact.
    try {
      await fs.delete(tmp);
    } catch (_) {
      // Best-effort cleanup; the original error is the one that matters.
    }
    rethrow;
  }
}

/// Centralized backup store: `~/.tina/backups/` (or whatever [storeDir] is).
///
/// Each entry lives at `<storeDir>/<id>-<sanitized-original-name>` and a hidden
/// registry file tracks them for LRU eviction. Pass a [FileSystem] so the whole
/// thing is testable in memory. Recovery is manual — [BackupEntry.path] is
/// reported in the tool result and documented in `docs/backup-recovery.md`.
class BackupStore {
  final FileSystem fs;
  final Directory storeDir;

  /// Monotonic tiebreaker so two backups in the same microsecond differ.
  int _counter = 0;

  BackupStore({required this.fs, required this.storeDir});

  static const String _registryName = '.tina-backup-registry.json';

  String get _registryPath => p.join(storeDir.path, _registryName);

  /// Back up [path] if it exists and is under the size cap. Returns the backup
  /// location, or `null` if there was nothing to back up (new file) or the file
  /// exceeded [kMaxBackupFileBytes]. Does not mutate [path].
  Future<BackupEntry?> backup(String path) async {
    if (!await fs.fileExists(path)) return null;

    final size = (await fs.readFileBytes(path)).length;
    if (size > kMaxBackupFileBytes) {
      _log.warning(
          'skipped backup of $path (${size}B > cap ${kMaxBackupFileBytes}B)');
      return null;
    }

    await _ensureStore();
    final entry = await _writeBackup(path, size);
    await _evictIfNeeded();
    return entry;
  }

  Future<void> _ensureStore() async {
    if (!await fs.directoryExists(storeDir.path)) {
      await fs.createDirectory(storeDir.path, recursive: true);
    }
  }

  Future<BackupEntry> _writeBackup(String originalPath, int size) async {
    final id = _nextId();
    final name = _sanitizeName(p.basename(originalPath));
    final dest = p.join(storeDir.path, '$id-$name');
    final content = await fs.readFileString(originalPath);
    await fs.writeFile(dest, content);

    final entry = BackupEntry(
      id: id,
      backupPath: dest,
      originalPath: originalPath,
      size: size,
      // ISO8601 for human-readable LRU ordering.
      time: DateTime.now().toIso8601String(),
    );
    final registry = await _readRegistry();
    registry.add(entry);
    await _writeRegistry(registry);
    return entry;
  }

  /// Evict oldest entries until we're under both the count cap and the
  /// total-byte ceiling. Called after every backup.
  Future<void> _evictIfNeeded() async {
    var registry = await _readRegistry();
    registry.sort((a, b) => a.time.compareTo(b.time)); // oldest first

    var totalBytes = registry.fold<int>(0, (sum, e) => sum + e.size);
    while (registry.length > kMaxBackups ||
        totalBytes > kMaxBackupTotalBytes) {
      final oldest = registry.removeAt(0);
      totalBytes -= oldest.size;
      if (await fs.fileExists(oldest.backupPath)) {
        await fs.delete(oldest.backupPath);
      }
    }
    await _writeRegistry(registry);
  }

  /// Exposes the parsed registry for tests (assert on LRU eviction / byte caps).
  /// Production code reads via [_readRegistry]; this is its public twin.
  Future<List<BackupEntry>> readRegistryForTest() => _readRegistry();

  Future<List<BackupEntry>> _readRegistry() async {
    if (!await fs.fileExists(_registryPath)) return [];
    try {
      final text = await fs.readFileString(_registryPath);
      final list = jsonDecode(text) as List<dynamic>;
      return list
          .map((e) => BackupEntry.fromJson(e as Map<String, dynamic>))
          .toList();
    } catch (_) {
      // Corrupt registry: don't let it block writes. Start fresh.
      return [];
    }
  }

  Future<void> _writeRegistry(List<BackupEntry> entries) async {
    final text =
        const JsonEncoder.withIndent('  ').convert(entries.map((e) => e.toJson()).toList());
    await fs.writeFile(_registryPath, text);
  }

  String _nextId() {
    _counter++;
    return '${DateTime.now().microsecondsSinceEpoch}-$_counter';
  }

  /// Strip path separators and odd characters so the backup filename can't
  /// escape the store dir or traverse on restore.
  String _sanitizeName(String name) {
    var cleaned = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '-');
    cleaned = cleaned.replaceAll(RegExp(r'-{2,}'), '-').trim().trimLeft();
    if (cleaned.isEmpty || cleaned == '.' || cleaned == '..') cleaned = 'file';
    return cleaned;
  }
}

/// A single backed-up file. [backupPath] is where to copy from to restore;
/// [originalPath] is where it came from (reported to the user).
class BackupEntry {
  final String id;
  final String backupPath;
  final String originalPath;
  final int size;
  final String time;

  const BackupEntry({
    required this.id,
    required this.backupPath,
    required this.originalPath,
    required this.size,
    required this.time,
  });

  factory BackupEntry.fromJson(Map<String, dynamic> json) => BackupEntry(
        id: json['id'] as String,
        backupPath: json['backupPath'] as String,
        originalPath: json['originalPath'] as String,
        size: json['size'] as int,
        time: json['time'] as String,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'backupPath': backupPath,
        'originalPath': originalPath,
        'size': size,
        'time': time,
      };
}
