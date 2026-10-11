import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';
import 'package:tina_sqlite/tina_sqlite.dart';

void main() {
  late Directory directory;
  late Database db;
  late TinaEntryLog log;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('tina-batch-');
    db = openTinaDatabase('${directory.path}/log.db',
        schemaVersion: 1, migrate: createEntryLogTable);
    log = TinaEntryLog.attach(db);
  });
  tearDown(() {
    if (!log.isBroken) db.close();
    directory.deleteSync(recursive: true);
  });

  test('one commit, ordered rowids, and nothing for an empty batch', () {
    var commits = 0;
    db.commitFilter = () {
      commits++;
      return true;
    };
    final ids = log.appendAll([
      {'n': 1},
      {'n': 2},
      {'n': 3}
    ]);
    expect(commits, 1);
    expect(log.readAll().map((row) => row.id), ids);
    expect(log.readAll().map((row) => row.payload['n']), [1, 2, 3]);
    expect(log.appendAll([]), isEmpty);
    expect(commits, 1);
  });

  test('serialization failure writes none of the batch', () {
    log.append({'n': 0});
    expect(
        () => log.appendAll([
              {'n': 1},
              {'n': Object()}
            ]),
        throwsA(anything));
    expect(log.readAll().map((row) => row.payload['n']), [0]);
    expect(log.isBroken, isFalse);
  });

  for (final failCommit in [false, true]) {
    test(
        'rollback entire batch on ${failCommit ? 'commit' : 'second insert'} failure',
        () {
      log.append({'n': 0});
      if (failCommit) {
        db.commitFilter = () => false;
      } else {
        db.execute('''CREATE TRIGGER refuse BEFORE INSERT ON entries
          WHEN json_extract(NEW.payload, '\$.n') = 2
          BEGIN SELECT RAISE(ABORT, 'injected failure'); END''');
      }
      expect(
          () => log.appendAll([
                {'n': 1},
                {'n': 2},
                {'n': 3}
              ]),
          throwsA(isA<TinaSqliteClosedException>()));
      expect(log.isBroken, isTrue);
      expect(
          () => log.appendAll([]), throwsA(isA<TinaSqliteClosedException>()));
      final recovered = sqlite3.open('${directory.path}/log.db');
      try {
        expect(
            TinaEntryLog.attach(recovered)
                .readAll()
                .map((row) => row.payload['n']),
            [0]);
        expect(
            recovered.select('PRAGMA integrity_check').single.values, ['ok']);
      } finally {
        recovered.close();
      }
    });
  }
}
