/// A JSON Lines file: one JSON object per line, appended under an
/// exclusive lock, read back oldest-first. The entry log's plain-file
/// twin — same entries, same order, different medium; the swap property
/// lives in `test/jsonlines_swap_test.dart`.
library;

import 'dart:convert';
import 'dart:io';

import 'entry_log.dart';

/// Thrown by [TinaJsonLinesFile.append] when the line does not survive a
/// round-trip through `jsonEncode`/`jsonDecode` — the file never holds a
/// line it cannot read back.
final class JsonLinesMismatchException implements Exception {
  const JsonLinesMismatchException(this.line, this.cause);

  /// The encoded form that failed to decode.
  final String line;
  final Object cause;

  @override
  String toString() =>
      'JsonLinesMismatchException: line not readable back: $line ($cause)';
}

/// A small JSON Lines file.
final class TinaJsonLinesFile {
  TinaJsonLinesFile(this.path);

  /// The file's path. Created on first append.
  final String path;

  RandomAccessFile? _lock;

  /// Encode, verify the line reads back, then append under lock.
  void append(Map<String, Object?> entry) {
    final line = jsonEncode(entry);
    // A line the file cannot read back must never reach the file.
    final decoded = jsonDecode(line);
    if (decoded is! Map ||
        decoded.length != entry.length ||
        !decoded.keys.every(entry.containsKey)) {
      throw JsonLinesMismatchException(line, StateError('shape changed'));
    }
    _acquire();
    try {
      final data = File(path);
      // Append at the byte level, synchronously: the bytes are on disk
      // before the lock drops, so a reader after a successful append
      // sees the line.
      final sink = data.openSync(mode: FileMode.append);
      try {
        sink.writeStringSync('$line\n');
        sink.flushSync();
      } finally {
        sink.closeSync();
      }
    } finally {
      _release();
    }
  }

  /// Every entry, oldest first. A truncated tail line (a crash
  /// mid-append) surfaces as a `FormatException` — never as silently
  /// dropped rows.
  List<Map<String, Object?>> readAll() {
    final file = File(path);
    if (!file.existsSync()) return const [];
    final text = file.readAsStringSync();
    if (text.isEmpty) return const [];
    return [
      for (final line in const LineSplitter().convert(text))
        if (line.isNotEmpty) (jsonDecode(line) as Map).cast<String, Object?>(),
    ];
  }

  /// How many entries the file holds.
  int get length => readAll().length;

  RandomAccessFile _acquire() {
    final lock = File('$path.lock').openSync(mode: FileMode.append);
    lock.lockSync(FileLock.exclusive);
    _lock = lock;
    return lock;
  }

  void _release() {
    final lock = _lock;
    _lock = null;
    if (lock == null) return;
    try {
      lock.unlockSync();
    } finally {
      lock.closeSync();
    }
  }
}

/// Write [entries] to the JSON Lines file at [jsonlPath] **and** to the
/// SQLite entry log [log] — the two media, same entries, same order.
/// Returns both readers; asserting that they agree is the caller's test
/// (`test/jsonlines_swap_test.dart` holds the property).
({
  TinaJsonLinesFile file,
  TinaEntryLog log,
}) swapJsonLinesWithSqlite({
  required String jsonlPath,
  required TinaEntryLog log,
  required List<Map<String, Object?>> entries,
}) {
  final file = TinaJsonLinesFile(jsonlPath);
  for (final e in entries) {
    file.append(e);
    log.append(e);
  }
  return (file: file, log: log);
}
