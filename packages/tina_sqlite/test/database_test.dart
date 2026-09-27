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
      expect(db.select('PRAGMA foreign_keys').first['foreign_keys'], 1);
      expect(db.select('PRAGMA busy_timeout').first['timeout'], 5000);
      // The migration's work is durable and visible.
      db.execute("INSERT INTO probe VALUES ('hello')");
      db.close();
    });

    test('a reopen on the current version does not migrate again', () {
      final p = path();
      openTinaDatabase(p, schemaVersion: 1,
          migrate: (db) => db.execute('CREATE TABLE probe (x TEXT)')).close();
      openTinaDatabase(
        p,
        schemaVersion: 1,
        // Would throw if the fresh-file branch ran again.
        migrate: (db) => throw StateError('migration ran twice'),
      ).close();
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
        () => openTinaDatabase(p, schemaVersion: 1,
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
        () => openTinaDatabase(p, schemaVersion: 1,
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
        () => openTinaDatabase(p, schemaVersion: 2,
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
        () => openTinaDatabase(p, schemaVersion: 1,
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
        () => openTinaDatabase(p, schemaVersion: 1,
            migrate: (db) => db.execute('CREATE TABLE probe (x TEXT)'),
            create: false),
        throwsA(isA<UnsupportedDatabaseVersion>()),
      );
    });
  });
}
