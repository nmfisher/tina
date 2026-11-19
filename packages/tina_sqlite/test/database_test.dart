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

  group('the migration ladder', () {
    // A hand-built v1 file: one table, real rows, stamped 1.
    Database buildV1(String p) {
      final db = sqlite3.open(p);
      db.execute('CREATE TABLE things (id INTEGER PRIMARY KEY, name TEXT)');
      db.execute("INSERT INTO things (name) VALUES ('kept-a'), ('kept-b')");
      db.userVersion = 1;
      db.close();
      return db;
    }

    test('an outdated file migrates stepwise with rows preserved', () {
      final p = path();
      buildV1(p);
      final steps = <int>[];
      final db = openTinaDatabase(
        p,
        schemaVersion: 3,
        migrate: (_) => throw StateError('fresh create must not run'),
        migrations: {
          1: (db) {
            steps.add(1);
            db.execute('ALTER TABLE things ADD COLUMN note TEXT');
          },
          2: (db) {
            steps.add(2);
            db.execute("UPDATE things SET note = 'migrated' WHERE id = 1");
          },
        },
      );
      addTearDown(db.close);
      expect(steps, [1, 2]);
      expect(db.userVersion, 3);
      expect(db.select('SELECT name, note FROM things ORDER BY id'), [
        {'name': 'kept-a', 'note': 'migrated'},
        {'name': 'kept-b', 'note': null},
      ]);
    });

    test('a current-version file is untouched by the ladder', () {
      final p = path();
      buildV1(p);
      final raw = sqlite3.open(p);
      raw.userVersion = 3;
      raw.close();
      final db = openTinaDatabase(p,
          schemaVersion: 3,
          migrate: (_) => throw StateError('fresh create must not run'),
          migrations: {
            1: (_) => throw StateError('step must not run'),
            2: (_) => throw StateError('step must not run'),
          });
      addTearDown(db.close);
      expect(db.userVersion, 3);
    });

    test('a future version is still refused', () {
      final p = path();
      buildV1(p);
      final raw = sqlite3.open(p);
      raw.userVersion = 4;
      raw.close();
      expect(
          () => openTinaDatabase(p,
              schemaVersion: 3,
              migrate: (_) {},
              migrations: {1: (_) {}, 2: (_) {}}),
          throwsA(isA<UnsupportedDatabaseVersion>()));
    });

    test('a ladder hole keeps the old refusal, file unchanged', () {
      final p = path();
      buildV1(p);
      expect(
          () => openTinaDatabase(p,
              schemaVersion: 3, migrate: (_) {}, migrations: {2: (_) {}}),
          throwsA(isA<UnsupportedDatabaseVersion>()));
      final raw = sqlite3.open(p);
      expect(raw.userVersion, 1);
      expect(raw.select('SELECT COUNT(*) c FROM things').single['c'], 2);
      raw.close();
    });

    test('a throwing step rolls back and leaves the version unstamped',
        () {
      final p = path();
      buildV1(p);
      expect(
          () => openTinaDatabase(p,
              schemaVersion: 2,
              migrate: (_) {},
              migrations: {
                1: (db) {
                  db.execute('ALTER TABLE things ADD COLUMN note TEXT');
                  throw StateError('step failed midway');
                }
              }),
          throwsStateError);
      // All-or-nothing: no half-added column, no stamp — the data is
      // exactly as it was, and a fixed step can run later.
      final raw = sqlite3.open(p);
      expect(raw.userVersion, 1);
      expect(
          raw.select('PRAGMA table_info(things)').map((r) => r['name']),
          ['id', 'name']);
      raw.close();
    });

    test('a concurrent outdated open adopts the winner\'s migration', () {
      final p = path();
      buildV1(p);
      var steps = 0;
      final db = openTinaDatabase(
        p,
        schemaVersion: 2,
        migrate: (_) => throw StateError('fresh create must not run'),
        migrations: {
          1: (db) {
            steps++;
            db.execute('ALTER TABLE things ADD COLUMN note TEXT');
          },
        },
        // The winning process migrates v1→2 while this opener holds
        // its stale v1 read; under the lock the winner's outcome is
        // adopted and the step never re-runs.
        afterFreshRead: () {
          final winner = sqlite3.open(p);
          winner.execute('PRAGMA busy_timeout=5000');
          winner.execute('BEGIN IMMEDIATE');
          winner.execute('ALTER TABLE things ADD COLUMN note TEXT');
          winner.userVersion = 2;
          winner.execute('COMMIT');
          winner.close();
        },
      );
      addTearDown(db.close);
      expect(steps, 0, reason: 'the winner already migrated');
      expect(db.userVersion, 2);
      db.execute("INSERT INTO things (name, note) VALUES ('after', 'ok')");
      expect(db.select("SELECT note FROM things WHERE name = 'after'").single,
          {'note': 'ok'});
    });

    test('a ladder without a fresh-create migration refuses a fresh file',
        () {
      expect(
          () => openTinaDatabase(path(),
              schemaVersion: 2, migrations: {1: (_) {}}),
          throwsA(isA<UnsupportedDatabaseVersion>()));
    });
  });
}
