import 'dart:convert';

import 'package:sqlite3/sqlite3.dart' show Database;
import 'package:tina_sqlite/tina_sqlite.dart';

import '../memory_store_api.dart';

/// The sqlite-backed memory store: one file per database (origin-keyed
/// repo file or the global file), WAL + busy timeout through
/// [openTinaDatabase] (the group-channel store's approach — concurrent
/// checkouts of the same repo may write at once).
final class SqliteMemoryStore implements MemoryStoreApi {
  SqliteMemoryStore._(this.file, this._db, this._scope);

  @override
  final String file;
  final Database _db;

  final MemoryScope _scope;

  @override
  MemoryScope get scope => _scope;

  /// The store file's schema version. Bump when the layout changes;
  /// the open step refuses anything newer than this code knows.
  static const schemaVersion = 1;

  /// Open (or create) the store at [path]. [scope] labels the tier
  /// this file serves (rows are tagged with it; promotion moves rows
  /// between files). Never silently degrades: a newer schema throws
  /// before anything is written.
  static SqliteMemoryStore open(String path, MemoryScope scope) {
    final Database db;
    try {
      db = openTinaDatabase(path,
          schemaVersion: schemaVersion, migrate: _migrate);
    } on Object catch (e) {
      throw MemoryStoreException('cannot open memory store $path', e);
    }
    return SqliteMemoryStore._(path, db, scope);
  }

  static void _migrate(Database db) {
    db.execute('CREATE TABLE memory ('
        'id INTEGER PRIMARY KEY, '
        'scope TEXT NOT NULL, '
        'category TEXT NOT NULL, '
        'text TEXT NOT NULL, '
        'created_at TEXT NOT NULL, '
        'updated_at TEXT NOT NULL, '
        'updated_by TEXT NOT NULL, '
        'last_recalled TEXT, '
        'recall_count INTEGER NOT NULL DEFAULT 0)');
    db.execute('CREATE INDEX memory_heat ON memory(recall_count)');
  }

  Never _fail(String doing, Object e) =>
      throw MemoryStoreException('memory store $file failed while $doing', e);

  static String _now() => DateTime.now().toUtc().toIso8601String();

  MemoryEntry _rowToEntry(dynamic row) => MemoryEntry(
        id: row['id'] as int,
        scope: MemoryScope.parse(row['scope'] as String),
        category: MemoryCategory.parse(row['category'] as String),
        text: row['text'] as String,
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
        updatedBy: row['updated_by'] as String,
        lastRecalled: row['last_recalled'] == null
            ? null
            : DateTime.parse(row['last_recalled'] as String),
        recallCount: row['recall_count'] as int,
      );

  @override
  MemoryEntry remember(String text,
      {required MemoryCategory category, required String updatedBy}) {
    if (text.trim().isEmpty) throw const FormatException('text is empty');
    try {
      final at = _now();
      _db.execute(
          'INSERT INTO memory '
          '(scope, category, text, created_at, updated_at, updated_by) '
          'VALUES (?, ?, ?, ?, ?, ?)',
          [scope.name, category.name, text, at, at, updatedBy]);
      return entry(_db.lastInsertRowId)!;
    } on Object catch (e) {
      _fail('remembering', e);
    }
  }

  @override
  MemoryEntry revise(int id, String text,
      {required DateTime expected,
      required String updatedBy,
      MemoryCategory? category}) {
    if (text.trim().isEmpty) throw const FormatException('text is empty');
    try {
      final current = entry(id);
      if (current == null) throw FormatException('no memory entry #$id');
      if (current.updatedAt != expected) {
        throw MemoryRevisionConflict(current);
      }
      _db.execute(
          'UPDATE memory SET text = ?, category = ?, updated_at = ?, '
          'updated_by = ? WHERE id = ?',
          [text, (category ?? current.category).name, _now(), updatedBy, id]);
      return entry(id)!;
    } on MemoryStoreException {
      rethrow;
    } on MemoryRevisionConflict {
      rethrow;
    } on Object catch (e) {
      _fail('revising #$id', e);
    }
  }

  @override
  MemoryEntry? forget(int id) {
    try {
      final current = entry(id);
      if (current == null) return null;
      _db.execute('DELETE FROM memory WHERE id = ?', [id]);
      return current;
    } on Object catch (e) {
      _fail('forgetting #$id', e);
    }
  }

  @override
  MemoryEntry? entry(int id) {
    try {
      final rows = _db
          .select('SELECT * FROM memory WHERE id = ?', [id]);
      if (rows.isEmpty) return null;
      return _rowToEntry(rows.single);
    } on Object catch (e) {
      _fail('reading #$id', e);
    }
  }

  @override
  List<MemoryEntry> recall(String query, {int limit = 20}) {
    if (limit < 1) throw const FormatException('limit must be at least 1');
    final terms = _terms(query);
    if (terms.isEmpty) return const [];
    try {
      var where = '';
      final params = <Object?>[];
      for (final term in terms) {
        where += '${where.isEmpty ? '' : ' AND '} lower(text) LIKE ?';
        params.add('%${term.toLowerCase()}%');
      }
      final rows = _db.select(
          'SELECT * FROM memory WHERE $where '
          'ORDER BY datetime(updated_at) DESC LIMIT ?',
          [...params, limit]);
      final matched = [for (final row in rows) _rowToEntry(row)];
      if (matched.isNotEmpty) {
        // Recalling bumps heat, durably: the hot tier reads these.
        final at = _now();
        for (final entry in matched) {
          _db.execute(
              'UPDATE memory SET last_recalled = ?, '
              'recall_count = recall_count + 1 WHERE id = ?',
              [at, entry.id]);
        }
      }
      return matched;
    } on Object catch (e) {
      _fail('recalling "$query"', e);
    }
  }

  @override
  List<MemoryEntry> hottest({int limit = 100}) {
    if (limit < 1) throw const FormatException('limit must be at least 1');
    try {
      final rows = _db.select(
          'SELECT * FROM memory '
          'ORDER BY recall_count DESC, '
          'datetime(COALESCE(last_recalled, updated_at)) DESC '
          'LIMIT ?',
          [limit]);
      return [for (final row in rows) _rowToEntry(row)];
    } on Object catch (e) {
      _fail('ranking hottest', e);
    }
  }

  @override
  List<MemoryEntry> list({MemoryCategory? category}) {
    try {
      final rows = category == null
          ? _db.select(
              'SELECT * FROM memory ORDER BY datetime(updated_at) DESC')
          : _db.select(
              'SELECT * FROM memory WHERE category = ? '
              'ORDER BY datetime(updated_at) DESC',
              [category.name]);
      return [for (final row in rows) _rowToEntry(row)];
    } on Object catch (e) {
      _fail('listing', e);
    }
  }

  @override
  Map<String, Object?> stats() {
    try {
      final total = _db
          .select('SELECT COUNT(*) AS n FROM memory')
          .single['n'] as int;
      final recalls = _db
          .select('SELECT COALESCE(SUM(recall_count), 0) AS n FROM memory')
          .single['n'] as int;
      final byCategory = <String, int>{};
      for (final row in _db.select(
          'SELECT category, COUNT(*) AS n FROM memory GROUP BY category')) {
        byCategory[row['category'] as String] = row['n'] as int;
      }
      return {
        'scope': scope.name,
        'file': file,
        'entries': total,
        'byCategory': byCategory,
        'recalls': recalls,
      };
    } on Object catch (e) {
      _fail('computing stats', e);
    }
  }

  @override
  void close() => _db.close();

  /// Lowercased query terms: alphanumeric runs, order preserved,
  /// duplicates dropped. Shared with the in-memory twin's matching so
  /// both stores answer the same query the same way.
  static List<String> _terms(String query) => [
        for (final match in RegExp(r'[A-Za-z0-9_./-]+').allMatches(query))
          match.group(0)!.toLowerCase()
      ].toSet().toList();
}

/// The store-level failure type (open, read, write).
final class MemoryStoreException implements Exception {
  const MemoryStoreException(this.message, [this.cause]);

  final String message;
  final Object? cause;

  @override
  String toString() =>
      'MemoryStoreException: $message${cause == null ? '' : ' ($cause)'}';
}

/// Escape hatch for callers that already hold a raw database (tests).
String debugMemorySchema() => jsonEncode(
    {'table': 'memory', 'columns': [
      'id', 'scope', 'category', 'text', 'created_at', 'updated_at',
      'updated_by', 'last_recalled', 'recall_count'
    ]});
