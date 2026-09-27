/// A generic namespaced key-value table. One schema (`kv`), every caller:
/// keys are TEXT, values are JSON-encodable Dart values stored as TEXT.
/// Per-feature tables stay the caller's business, built through the open
/// callback — this store only covers the cases every feature ends up
/// needing: a string key, a value, read and write.
library;

import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';

import 'poison_pill.dart';

/// A kv store on an already-open [Database]. The `kv` table (or [table])
/// is created if missing — idempotent, so a kv store and an entry log can
/// share one connection and one migration stamp.
final class TinaKv with PoisonPillStore {
  TinaKv._(this.db, this.storeLabel, this._table);

  /// Attach a kv store to [db], creating its table if missing.
  factory TinaKv.attach(Database db, {String table = 'kv'}) {
    db.execute('CREATE TABLE IF NOT EXISTS "$table" ('
        'key TEXT PRIMARY KEY, '
        'value TEXT NOT NULL)');
    return TinaKv._(db, 'TinaKv($table)', table);
  }

  @override
  Database? db;

  @override
  final String storeLabel;

  final String _table;

  /// Read [key]; null when absent.
  Object? get(String key) => guard((d) {
        final rows = d.select(
            'SELECT value FROM "$_table" WHERE key = ?', [key]);
        if (rows.isEmpty) return null;
        return jsonDecode(rows.first['value'] as String);
      });

  /// Write [key] = [value] (insert or replace). The value must survive
  /// `jsonEncode` — strings, numbers, bools, null, lists, maps.
  void set(String key, Object? value) => guardWrite((d) {
        d.execute(
          'INSERT INTO "$_table" (key, value) VALUES (?, ?) '
          'ON CONFLICT(key) DO UPDATE SET value = excluded.value',
          [key, jsonEncode(value)],
        );
      });

  /// Remove [key]. Returns whether it was there.
  bool delete(String key) => guardWrite((d) {
        d.execute('DELETE FROM "$_table" WHERE key = ?', [key]);
        return d.updatedRows > 0;
      });

  /// Every key present, sorted.
  List<String> keys() => guard((d) => [
        for (final row
            in d.select('SELECT key FROM "$_table" ORDER BY key'))
          row['key'] as String,
      ]);
}

/// The schema piece for callers who build their own migration.
void createKvTable(Database db, {String table = 'kv'}) {
  db.execute('CREATE TABLE IF NOT EXISTS "$table" ('
      'key TEXT PRIMARY KEY, '
      'value TEXT NOT NULL)');
}
