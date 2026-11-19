/// The versioned open-or-create step, shared by every store in the
/// package:
///
/// - `user_version == current` → nothing to do (return fast);
/// - `user_version > current` → **throw** — a future tina must never
///   silently write into a schema it does not know;
/// - `user_version == 0` → run the fresh-create [TinaMigration] in
///   **one transaction** and stamp the version;
/// - `0 < user_version < current` → run the caller's **migration
///   ladder**: the steps `migrations[from]`, `from+1`, … in **one
///   transaction** (all-or-nothing — a step that throws leaves the
///   transaction rolled back, the version unstamped, and the data
///   never half-migrated), then stamp the current version. A version
///   with no step in the ladder → unsupported, exactly as before.
///
/// Pragmas are set at open, before the migration, exactly as the
/// classification store sets them: foreign keys on, a busy timeout so a
/// second process waits instead of erroring, WAL so readers don't block
/// the writer.
library;

import 'package:sqlite3/sqlite3.dart';

/// The pragma block every tina database gets at open.
void _setPragmas(Database db, String file) {
  db.execute('PRAGMA foreign_keys=ON');
  db.execute('PRAGMA busy_timeout=5000');
  final mode = db.select('PRAGMA journal_mode=WAL').single['journal_mode'];
  // SQLite cannot put an in-memory database into WAL mode. File-backed
  // stores must actually enter WAL, rather than silently using another mode.
  if (mode != 'wal' && !(file == ':memory:' && mode == 'memory')) {
    throw StateError('Cannot enable WAL for $file (journal_mode=$mode)');
  }
  // A successful write acknowledges the FULL commit, including its WAL sync.
  // Set this on every connection; synchronous is not a persistent file setting.
  db.execute('PRAGMA synchronous=FULL');
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
///
/// Concurrent first opens are safe: the version is re-read under the
/// write lock, so the loser of the create (or migrate) race adopts the
/// winner's migration instead of re-running it. [afterFreshRead] lets a
/// test run as that winning process between the stale version read and
/// the lock — for a fresh read AND for an outdated-version read alike.
Database openTinaDatabase(
  String file, {
  required int schemaVersion,
  TinaMigration? migrate,

  /// The stepwise ladder for EXISTING files: `migrations[n]` upgrades a
  /// `user_version == n` database to `n + 1`. Opening an outdated file
  /// runs every step from its version to the current one, in one
  /// transaction. A version with no step stays unsupported (the throw
  /// this function has always made).
  Map<int, TinaMigration> migrations = const {},
  bool create = true,
  void Function()? afterFreshRead,
}) {
  final db = sqlite3.open(file,
      mode: create ? OpenMode.readWriteCreate : OpenMode.readWrite);
  try {
    _setPragmas(db, file);
    final version = db.userVersion;
    if (version == schemaVersion) return db;
    if (version > schemaVersion) {
      throw UnsupportedDatabaseVersion(file, version, schemaVersion);
    }
    if (version == 0 && !create) {
      throw UnsupportedDatabaseVersion(file, version, schemaVersion);
    }
    // Test seam for the concurrent-open races: invoked while this
    // opener holds its stale version read, before it takes the lock.
    afterFreshRead?.call();
    db.execute('BEGIN IMMEDIATE');
    try {
      // Re-read under the write lock: a second opener can have read
      // the old version before the first committed, and must not
      // re-run a step after waiting for that commit (a CREATE or ALTER
      // would collide). The lock-holder that migrated first is
      // authoritative: adopt its outcome and continue from wherever
      // the file actually is.
      var locked = db.userVersion;
      if (locked == schemaVersion) {
        db.execute('COMMIT');
        return db;
      }
      if (locked > schemaVersion) {
        throw UnsupportedDatabaseVersion(file, locked, schemaVersion);
      }
      if (locked == 0 && !create) {
        throw UnsupportedDatabaseVersion(file, locked, schemaVersion);
      }
      while (locked < schemaVersion) {
        // A fresh file with a full-create migration reaches the
        // current schema in ONE step; every other step moves exactly
        // one version up the ladder.
        final TinaMigration? step;
        var advancesTo = locked + 1;
        if (locked == 0 && migrate != null) {
          step = migrate;
          advancesTo = schemaVersion;
        } else {
          step = locked == 0 ? migrations[0] : migrations[locked];
        }
        if (step == null) {
          // A ladder hole: this code has no path from `locked`.
          throw UnsupportedDatabaseVersion(file, locked, schemaVersion);
        }
        step(db);
        locked = advancesTo;
      }
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
