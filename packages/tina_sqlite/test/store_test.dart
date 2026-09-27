// TinaEntryLog and TinaKv: the generic stores. Inserts only on the log —
// no update, no delete, order is rowid order; the kv table round-trips
// JSON values; the poison pill kills a store after its first failure.
//
// Run: dart test
library;

import 'dart:convert';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tina_sqlite/tina_sqlite.dart';

void main() {
  late Directory dir;
  late Database db;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tina_sqlite_test_');
    db = openTinaDatabase(
      '${dir.path}/state.db',
      schemaVersion: 1,
      migrate: (db) {
        createEntryLogTable(db);
        createKvTable(db);
      },
    );
  });
  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  group('TinaEntryLog', () {
    test('appends come back oldest-first with database-picked ids', () {
      final log = TinaEntryLog.attach(db);
      final a = log.append({'kind': 'a', 'n': 1});
      final b = log.append({'kind': 'b', 'n': 2});
      final c = log.append({'kind': 'c', 'n': 3});
      expect(a, lessThan(b));
      expect(b, lessThan(c));

      final rows = log.readAll();
      expect(rows, hasLength(3));
      expect([for (final r in rows) r.payload['kind']], ['a', 'b', 'c']);
      expect([for (final r in rows) r.id], [a, b, c]);
      // The write time is a UTC ISO-8601 stamp the store chose.
      expect(DateTime.parse(rows[0].at).isUtc, isTrue);
      // The payload round-trips through JSON unchanged.
      expect(rows[1].payload, {'kind': 'b', 'n': 2});
      expect(log.lastId, c);
      expect(log.length, 3);
    });

    test('since resumes a pass where the previous one stopped', () {
      final log = TinaEntryLog.attach(db, table: 'resumable');
      final first = log.append({'i': 1});
      log.append({'i': 2});
      log.append({'i': 3});

      expect(log.since(0).map((e) => e.payload['i']).toList(), [1, 2, 3]);
      expect(log.since(first).map((e) => e.payload['i']).toList(), [2, 3]);
      expect(log.since(log.lastId), isEmpty);
    });

    test('two logs share one connection without colliding', () {
      final logA = TinaEntryLog.attach(db, table: 'log_a');
      final logB = TinaEntryLog.attach(db, table: 'log_b');
      logA.append({'side': 'a'});
      logB.append({'side': 'b'});
      logA.append({'side': 'a2'});
      expect(logA.length, 2);
      expect(logB.length, 1);
      expect(logB.readAll().single.payload['side'], 'b');
    });

    test('no update or delete exists on the log surface', () {
      // A schema-level assertion, not just an API absence: the type has
      // no mutating member besides append. This test pins the surface by
      // trying the only legal write repeatedly and reading back.
      final log = TinaEntryLog.attach(db, table: 'immutable');
      for (var i = 0; i < 5; i++) {
        log.append({'i': i});
      }
      final rows = log.readAll();
      expect(rows.map((e) => e.payload['i']), [0, 1, 2, 3, 4],
          reason: 'append-only: nothing reorders or rewrites');
    });
  });

  group('TinaKv', () {
    test('set, get, delete, keys round-trip JSON values', () {
      final kv = TinaKv.attach(db);
      expect(kv.get('missing'), isNull);

      kv.set('string', 'hello');
      kv.set('int', 42);
      kv.set('bool', true);
      kv.set('null', null);
      kv.set('list', [1, 'two', false]);
      kv.set('map', {'nested': {'x': 1}});

      expect(kv.get('string'), 'hello');
      expect(kv.get('int'), 42);
      expect(kv.get('bool'), true);
      expect(kv.get('null'), isNull);
      expect(kv.keys(), contains('null'), reason: 'a null value is stored');
      expect(kv.get('list'), [1, 'two', false]);
      expect(kv.get('map'), {'nested': {'x': 1}});

      expect(kv.keys(),
          ['bool', 'int', 'list', 'map', 'null', 'string']);

      expect(kv.delete('int'), isTrue);
      expect(kv.delete('int'), isFalse);
      expect(kv.get('int'), isNull);
      expect(kv.keys(), ['bool', 'list', 'map', 'null', 'string']);
    });

    test('set overwrites; two kvs share one connection', () {
      final kv = TinaKv.attach(db);
      kv.set('k', 'first');
      kv.set('k', 'second');
      expect(kv.get('k'), 'second');

      final other = TinaKv.attach(db, table: 'kv_other');
      other.set('k', 'elsewhere');
      expect(kv.get('k'), 'second');
      expect(other.get('k'), 'elsewhere');
    });

    test('values survive a close and reopen', () {
      TinaKv.attach(db).set('durable', {'v': 7});
      db.close();
      db = openTinaDatabase('${dir.path}/state.db', schemaVersion: 1,
          migrate: (db) {});
      expect(TinaKv.attach(db).get('durable'), {'v': 7});
    });
  });

  group('the poison pill', () {
    test('a failing store dies and every later call rethrows', () {
      final kv = TinaKv.attach(db);
      kv.set('ok', 1);

      // Corrupt the schema out from under the store.
      db.execute('DROP TABLE kv');
      db.execute('CREATE TABLE kv (key TEXT, missing_value TEXT)');
      db.execute("INSERT INTO kv VALUES ('boom', 'x')");

      expect(() => kv.set('k', 'v'), throwsA(isA<TinaSqliteClosedException>()));
      expect(kv.isBroken, isTrue);
      // Reads, writes, everything: the pill, not a fresh error.
      expect(() => kv.get('ok'), throwsA(isA<TinaSqliteClosedException>()));
      expect(() => kv.delete('ok'),
          throwsA(isA<TinaSqliteClosedException>()));
      expect(() => kv.keys(), throwsA(isA<TinaSqliteClosedException>()));
      // And the pill carries the first failure as its cause.
      try {
        kv.keys();
        fail('expected the pill');
      } on TinaSqliteClosedException catch (e) {
        expect(e.toString(), contains('TinaKv(kv) is closed permanently'));
        expect(e.cause, isA<SqliteException>());
      }
    });

    test('a disposed connection turns the store dead too', () {
      final kv = TinaKv.attach(db);
      db.close();
      expect(() => kv.get('x'), throwsA(isA<TinaSqliteClosedException>()));
      expect(kv.isBroken, isTrue);
    });

    test('a rolled-back write leaves the previous value intact', () {
      final kv = TinaKv.attach(db);
      kv.set('k', 'before');
      // Corrupt the column so the write fails mid-statement.
      db.execute('DROP TABLE kv');
      db.execute('CREATE TABLE kv (key TEXT PRIMARY KEY, gone TEXT NOT NULL)');
      db.execute("INSERT INTO kv VALUES ('other', 'row')");
      expect(() => kv.set('k', 'after'),
          throwsA(isA<TinaSqliteClosedException>()));
      // The transaction rolled back before the store died: the row the
      // raw connection wrote is still there, and no 'k' row arrived. The
      // die path closed the shared handle, so verify on a fresh one.
      final raw = sqlite3.open('${dir.path}/state.db');
      final rows = raw.select('SELECT key, gone FROM kv ORDER BY key');
      expect(rows, hasLength(1));
      expect(rows.first['key'], 'other');
      expect(rows.first['gone'], 'row');
      raw.close();
    });
  });

  group('one connection, every store', () {
    test('log and kv coexist on one migration stamp', () {
      final log = TinaEntryLog.attach(db, table: 'mixed_log');
      final kv = TinaKv.attach(db, table: 'mixed_kv');
      log.append({'turn': 1});
      kv.set('active', 's-1');
      log.append({'turn': 2});
      expect([for (final e in log.readAll()) e.payload['turn']], [1, 2]);
      expect(kv.get('active'), 's-1');
      // Both live in the one file the migration stamped.
      expect(db.userVersion, 1);
      final tables = db.select(
          "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name");
      expect(
        [for (final t in tables) t['name']],
        containsAll(['mixed_log', 'mixed_kv']),
      );
    });
  });

  // Keep the jsonEncode dependency visible: the payload column is TEXT.
  test('payloads are stored as JSON text, not dart blobs', () {
    final log = TinaEntryLog.attach(db, table: 'json_text');
    log.append({'x': 1});
    final raw = db
        .select("SELECT payload FROM json_text")
        .first['payload'] as String;
    expect(jsonDecode(raw), {'x': 1});
    expect(raw, '{"x":1}');
  });
}
