/// A generic append-only entry log: one table, inserts only, rows come
/// back oldest-first by rowid. The schema exposes no update or delete and
/// no method of this class does either. Feature-specific columns are not
/// here — the payload is one JSON text column, so every caller shares the
/// schema and stays out of each other's way.
///
/// The log is the durable twin of a JSON Lines file ([TinaJsonLinesFile]):
/// same entries, same order, different medium. `since(rowid)` resumes a
/// pass where the previous one stopped.
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'database.dart';
import 'poison_pill.dart';

/// An append-only log on an already-open [Database]. The `entries` table
/// (or [table], when named) is created through the same versioned
/// migration the caller runs via [openTinaDatabase] — attach the log
/// there, or later with [createTable] on a connection already open.
final class TinaEntryLog with PoisonPillStore {
  TinaEntryLog._(this.db, this.storeLabel, this._table);

  /// Attach a log to [db], creating its table if missing. Idempotent:
  /// `CREATE TABLE IF NOT EXISTS`, so a log and a kv store can share one
  /// connection and one migration stamp.
  factory TinaEntryLog.attach(
    Database db, {
    String table = 'entries',
  }) {
    db.execute('CREATE TABLE IF NOT EXISTS "$table" ('
        'id INTEGER PRIMARY KEY, '
        'at TEXT NOT NULL, '
        'payload TEXT NOT NULL)');
    return TinaEntryLog._(db, 'TinaEntryLog($table)', table);
  }

  @override
  Database? db;

  @override
  final String storeLabel;

  final String _table;

  /// Append one entry; the database picks the rowid. Returns it.
  int append(Map<String, Object?> entry) => guardWrite((d) {
        final at = DateTime.now().toUtc().toIso8601String();
        d.execute(
          'INSERT INTO "$_table" (at, payload) VALUES (?, ?)',
          [at, jsonEncode(entry)],
        );
        return d.lastInsertRowId;
      });

  /// Every entry, oldest first. `payload` is decoded; `at` stays a string.
  List<TinaLogEntry> readAll() => _select();

  /// Entries newer than [afterId] (exclusive), oldest first.
  List<TinaLogEntry> since(int afterId) => _select(afterId: afterId);

  /// The highest rowid assigned so far, or 0 for an empty log.
  int get lastId => guard(
        (d) => d.select('SELECT COALESCE(MAX(id), 0) AS m FROM "$_table"')
            .first['m'] as int,
      );

  /// How many entries the log holds.
  int get length =>
      guard((d) => d.select('SELECT COUNT(*) AS c FROM "$_table"').first['c']
          as int);

  List<TinaLogEntry> _select({int? afterId}) => guard((d) {
        final rows = afterId == null
            ? d.select('SELECT id, at, payload FROM "$_table" ORDER BY id')
            : d.select(
                'SELECT id, at, payload FROM "$_table" WHERE id > ? '
                'ORDER BY id',
                [afterId]);
        return [
          for (final row in rows)
            TinaLogEntry(
              row['id'] as int,
              row['at'] as String,
              (row['payload'] as String).isEmpty
                  ? const {}
                  : (jsonDecode(row['payload'] as String)
                      as Map<String, Object?>),
            ),
        ];
      });
}

/// One log row: its database-assigned id, its write time, its payload.
final class TinaLogEntry {
  const TinaLogEntry(this.id, this.at, this.payload);

  /// Rowid picked by the database. Monotonic; gaps after crashes are fine.
  final int id;

  /// UTC write time, ISO-8601.
  final String at;

  /// The appended map, decoded.
  final Map<String, Object?> payload;
}

/// The schema piece for callers who build their own migration: run this
/// inside a [TinaMigration] to stamp the log table into the same versioned
/// transaction instead of attaching one afterwards.
void createEntryLogTable(Database db, {String table = 'entries'}) {
  db.execute('CREATE TABLE IF NOT EXISTS "$table" ('
      'id INTEGER PRIMARY KEY, '
      'at TEXT NOT NULL, '
      'payload TEXT NOT NULL)');
}
