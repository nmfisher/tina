/// The versioned open-or-create step, shared by every store in the
/// package. The shape is `SqliteClassificationStore`'s `schema()`:
///
/// - `user_version == current` → nothing to do (return fast);
/// - `user_version > current` → **throw** — a future tina must never
///   silently write into a schema it does not know;
/// - `user_version == 0` → run [TinaMigration] in **one transaction** and
///   stamp the version; a migration that throws leaves the transaction
///   rolled back and the version unstamped;
/// - anything else → unsupported.
///
/// Pragmas are set at open, before the migration, exactly as the
/// classification store sets them: foreign keys on, a busy timeout so a
/// second process waits instead of erroring, WAL so readers don't block
/// the writer.
library;

import 'package:sqlite3/sqlite3.dart';

/// The pragma block every tina database gets at open.
void _setPragmas(Database db) {
  db.execute('PRAGMA foreign_keys=ON');
  db.execute('PRAGMA busy_timeout=5000');
  db.execute('PRAGMA journal_mode=WAL');
}

/// Thrown when the file on disk was written by a different (usually
/// newer) schema than this code knows.
final class UnsupportedDatabaseVersion implements Exception {
  const UnsupportedDatabaseVersion(this.file, this.found, this.expected);

  /// The path that was opened.
  final String file;

  /// The `user_version` found on disk.
  final int found;

  /// The `user_version` this code supports.
  final int expected;

  @override
  String toString() =>
      'UnsupportedDatabaseVersion: $file has user_version $found, '
      'this code supports $expected';
}

/// Creates the schema for a fresh database, inside the transaction the
/// open step wraps around it. Create tables and indexes here; the open
/// step stamps `user_version` after this returns without throwing.
typedef TinaMigration = void Function(Database db);

/// Open (or create) [file] and bring its schema to the caller's current
/// version. Creation and the version stamp happen in one transaction; an
/// existing current-version database is returned untouched. The caller
/// owns the returned handle ([Database.close] it).
Database openTinaDatabase(
  String file, {
  required int schemaVersion,
  required TinaMigration migrate,
  bool create = true,
}) {
  final db = sqlite3.open(file, mode: create ? OpenMode.readWriteCreate : OpenMode.readWrite);
  try {
    _setPragmas(db);
    final version = db.userVersion;
    if (version == schemaVersion) return db;
    if (version > schemaVersion) {
      throw UnsupportedDatabaseVersion(file, version, schemaVersion);
    }
    // version == 0: fresh file (sqlite defaults user_version to 0).
    if (version != 0) {
      throw UnsupportedDatabaseVersion(file, version, schemaVersion);
    }
    if (!create) {
      throw UnsupportedDatabaseVersion(file, version, schemaVersion);
    }
    db.execute('BEGIN IMMEDIATE');
    try {
      migrate(db);
      db.userVersion = schemaVersion;
      db.execute('COMMIT');
    } on Object {
      db.execute('ROLLBACK');
      rethrow;
    }
    return db;
  } on Object {
    db.close();
    rethrow;
  }
}
