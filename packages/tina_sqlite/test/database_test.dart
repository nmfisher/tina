// openTinaDatabase: the versioned open-or-create step, exactly the rules
// SqliteClassificationStore.schema() runs by.
//
// Run: dart test
library;

import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tina_sqlite/tina_sqlite.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tina_sqlite_test_');
  });
  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  String path([String name = 'state.db']) =>
      Directory('${dir.path}/$name').path;

  group('create on a fresh file', () {
    test('runs the migration once and stamps the version', () {
      var migrations = 0;
      final db = openTinaDatabase(
        path(),
        schemaVersion: 3,
        migrate: (db) {
          migrations++;
          db.execute('CREATE TABLE probe (x TEXT)');
        },
      );
      expect(migrations, 1);
      expect(db.userVersion, 3);
      expect(db.select('PRAGMA journal_mode').first['journal_mode'], 'wal');
      expect(db.select('PRAGMA synchronous').single['synchronous'], 2);
      expect(db.select('PRAGMA foreign_keys').first['foreign_keys'], 1);
      expect(db.select('PRAGMA busy_timeout').first['timeout'], 5000);
      // The migration's work is durable and visible.
      db.execute("INSERT INTO probe VALUES ('hello')");
      db.close();
    });

    test('a reopen on the current version does not migrate again', () {
      final p = path();
      openTinaDatabase(p,
          schemaVersion: 1,
          migrate: (db) => db.execute('CREATE TABLE probe (x TEXT)')).close();
      openTinaDatabase(
        p,
        schemaVersion: 1,
        // Would throw if the fresh-file branch ran again.
        migrate: (db) => throw StateError('migration ran twice'),
      ).close();
    });

    // Regression (CI run 43998943385): two processes opening one fresh
    // file. The loser reads user_version 0 before the winner commits,
    // then takes the write lock after that commit — and must adopt the
    // winner's migration, not re-run it (CREATE TABLE would collide and
    // crash the process with an unhandled SqliteException, exit 255).
    test('a concurrent first open adopts the winner\'s migration', () {
      final p = path();
      var migrations = 0;
      final db = openTinaDatabase(
        p,
        schemaVersion: 1,
        migrate: (db) {
          migrations++;
          db.execute('CREATE TABLE probe (x TEXT)');
        },
        // Play the winning process while this opener holds its stale
        // fresh-file read: full migration + stamp, committed from a
        // second connection before BEGIN IMMEDIATE is attempted.
        afterFreshRead: () {
          final winner = sqlite3.open(p);
          winner.execute('PRAGMA busy_timeout=5000');
          winner.execute('BEGIN IMMEDIATE');
          winner.execute('CREATE TABLE probe (x TEXT)');
          winner.userVersion = 1;
          winner.execute('COMMIT');
          winner.close();
        },
      );
      addTearDown(db.close);
      expect(migrations, 0, reason: 'the winner already migrated');
      expect(db.userVersion, 1);
      // The adopted schema is usable through this connection.
      db.execute("INSERT INTO probe VALUES ('adopted')");
      expect(db.select('SELECT x FROM probe').single['x'], 'adopted');
    });

    test('a migration that throws leaves the file unmigrated', () {
      final p = path();
      expect(
        () => openTinaDatabase(
          p,
          schemaVersion: 1,
          migrate: (db) {
            db.execute('CREATE TABLE half (x TEXT)');
            throw StateError('schema changed under us');
          },
        ),
        throwsStateError,
      );
      // The transaction rolled back: no half table, no version stamp. A
      // later open can migrate cleanly from zero.
      final db = sqlite3.open(p);
      expect(db.userVersion, 0);
      expect(
        db.select("SELECT name FROM sqlite_master WHERE type='table'"),
        isEmpty,
      );
      db.close();
      var migrated = false;
      openTinaDatabase(p, schemaVersion: 1, migrate: (db) {
        migrated = true;
      }).close();
      expect(migrated, isTrue);
    });

    test('a file that is not a database throws instead of creating', () {
      final p = path('junk.db');
      File(p).writeAsStringSync('this is not sqlite');
      expect(
        () => openTinaDatabase(p,
            schemaVersion: 1,
            migrate: (db) => db.execute('CREATE TABLE probe (x TEXT)')),
        throwsA(isA<SqliteException>()),
      );
    });
  });

  group('a foreign or unsupported version', () {
    test('a newer file is refused, never written to', () {
      final p = path();
      final db = sqlite3.open(p);
      db.userVersion = 99;
      db.close();
      expect(
        () => openTinaDatabase(p,
            schemaVersion: 1,
            migrate: (db) => db.execute('CREATE TABLE probe (x TEXT)')),
        throwsA(isA<UnsupportedDatabaseVersion>()
            .having((e) => e.found, 'found', 99)
            .having((e) => e.expected, 'expected', 1)
            .having((e) => e.toString(), 'toString', contains(p))),
      );
    });

    test('a version between 0 and current is refused too', () {
      final p = path();
      final db = sqlite3.open(p);
      db.userVersion = 1;
      db.close();
      expect(
        () => openTinaDatabase(p,
            schemaVersion: 2,
            migrate: (db) => db.execute('CREATE TABLE probe (x TEXT)')),
        throwsA(isA<UnsupportedDatabaseVersion>()
            .having((e) => e.found, 'found', 1)),
      );
    });
  });

  group('create: false', () {
    test('an absent file is not created', () {
      final p = path('never.db');
      expect(
        () => openTinaDatabase(p,
            schemaVersion: 1,
            migrate: (db) => db.execute('CREATE TABLE probe (x TEXT)'),
            create: false),
        throwsA(isA<SqliteException>()),
      );
      expect(File(p).existsSync(), isFalse,
          reason: 'opening must not have created the file');
    });

    test('an existing but unstamped file is refused', () {
      final p = path();
      sqlite3.open(p).close(); // a valid, empty, version-0 database
      expect(
        () => openTinaDatabase(p,
            schemaVersion: 1,
            migrate: (db) => db.execute('CREATE TABLE probe (x TEXT)'),
            create: false),
        throwsA(isA<UnsupportedDatabaseVersion>()),
      );
    });
  });

  test('each connection resets synchronous to FULL, including memory', () {
    for (final file in [path(), ':memory:']) {
      final first = openTinaDatabase(file, schemaVersion: 1, migrate: (_) {});
      first.execute('PRAGMA synchronous=NORMAL');
      final second = openTinaDatabase(file, schemaVersion: 1, migrate: (_) {});
      expect(second.select('PRAGMA synchronous').single['synchronous'], 2);
      expect(second.select('PRAGMA journal_mode').single['journal_mode'],
          file == ':memory:' ? 'memory' : 'wal');
      second.close();
      first.close();
      final reopened =
          openTinaDatabase(file, schemaVersion: 1, migrate: (_) {});
      expect(reopened.select('PRAGMA synchronous').single['synchronous'], 2);
      reopened.close();
    }
  });

  test('refuses a temporary file that cannot enter WAL before migrating', () {
    var migrated = false;
    // An empty filename asks SQLite for a temporary on-disk database. It
    // remains in delete journal mode, so it cannot meet the store contract.
    expect(
        () => openTinaDatabase('', schemaVersion: 1, migrate: (_) {
              migrated = true;
            }),
        throwsStateError);
    expect(migrated, isFalse);
  });
}
