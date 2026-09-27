// The swap property: a reader on the JSON Lines file and a reader on the
// SQLite entry log observe the same entries in the same order — the
// durable log and the file agree line-for-line, so backing either with
// the other changes no observable behavior.
//
// Run: dart test
library;

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_sqlite/tina_sqlite.dart';

void main() {
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('tina_sqlite_swap_');
  });
  tearDown(() {
    dir.deleteSync(recursive: true);
  });

  /// Entries with shapes a real session would write: nested payloads,
  /// unicode, empty-ish values, everything a JSON line must survive.
  List<Map<String, Object?>> batch() => [
        {'kind': 'turn', 'id': 't-0', 'text': 'hello'},
        {
          'kind': 'tool',
          'name': 'write',
          'input': {'filePath': 'a.txt', 'content': 'x'},
          'nested': {'deep': [1, 2, {'z': true}]},
        },
        {'kind': 'turn', 'id': 't-1', 'text': 'héllo — ünïcode ✓'},
        {'kind': 'kv', 'value': ''},
        {'kind': 'numbers', 'ints': [0, -1, 9007199254740991], 'pi': 3.14},
      ];

  group('the swap property: file and log agree', () {
    test('the same batch lands identically in both media', () {
      final db = openTinaDatabase('${dir.path}/swap.db', schemaVersion: 1,
          migrate: (db) => createEntryLogTable(db));
      final entries = batch();
      final (file: file, log: log) = swapJsonLinesWithSqlite(
        jsonlPath: '${dir.path}/events.jsonl',
        log: TinaEntryLog.attach(db),
        entries: entries,
      );

      final fromLog = [
        for (final e in log.readAll()) e.payload,
      ];
      expect(fromLog, entries);
      expect(file.readAll(), entries);
      expect(file.readAll(), fromLog,
          reason: 'the two media are interchangeable');

      db.close();
    });

    test('either medium rebuilds the other, losslessly', () {
      final db = openTinaDatabase('${dir.path}/rebuild.db', schemaVersion: 1,
          migrate: (db) => createEntryLogTable(db));
      final entries = batch();
      final (file: file, log: log) = swapJsonLinesWithSqlite(
        jsonlPath: '${dir.path}/events.jsonl',
        log: TinaEntryLog.attach(db),
        entries: entries,
      );

      // Rebuild the file FROM the log: the file's bytes carry the same
      // objects the log's rows carry.
      final rebuilt = TinaJsonLinesFile('${dir.path}/rebuilt.jsonl');
      for (final e in log.readAll()) {
        rebuilt.append(e.payload);
      }
      expect(rebuilt.readAll(), file.readAll());

      // And rebuild the log FROM the file.
      final reborn = openTinaDatabase('${dir.path}/reborn.db',
          schemaVersion: 1, migrate: (db) => createEntryLogTable(db));
      final log2 = TinaEntryLog.attach(reborn);
      for (final e in file.readAll()) {
        log2.append(e);
      }
      expect([for (final e in log2.readAll()) e.payload], entries);

      db.close();
      reborn.close();
    });

    test('interleaved appends keep both media in lockstep', () {
      final db = openTinaDatabase('${dir.path}/interleave.db',
          schemaVersion: 1, migrate: (db) => createEntryLogTable(db));
      final entries = batch();
      final (file: file, log: log) = swapJsonLinesWithSqlite(
        jsonlPath: '${dir.path}/events.jsonl',
        log: TinaEntryLog.attach(db),
        entries: entries,
      );

      // A late entry lands in both media — the two are mirrors — then
      // more entries arrive through one medium at a time, each appended
      // to the other as well. Readers of either still see one shared
      // history; order matches everywhere.
      final lateEntry = {'kind': 'late', 'via': 'both'};
      file.append(lateEntry);
      log.append(lateEntry);
      final viaFile = {'kind': 'late', 'via': 'file'};
      file.append(viaFile);
      log.append(viaFile);
      final viaLog = {'kind': 'late', 'via': 'log'};
      log.append(viaLog);
      file.append(viaLog);

      final fileKinds = [for (final e in file.readAll()) e['kind']];
      final logKinds = [for (final e in log.readAll()) e.payload['kind']];
      expect(file.length, log.length);
      expect(fileKinds, logKinds);
      expect(fileKinds.last, 'late');
      expect(file.readAll().last, viaLog);
      expect(log.readAll().last.payload, viaLog);
      db.close();
    });

    test('resuming from a swapped file with since() skips nothing', () {
      final db = openTinaDatabase('${dir.path}/resume.db', schemaVersion: 1,
          migrate: (db) => createEntryLogTable(db));
      final entries = batch();
      final (file: file, log: log) = swapJsonLinesWithSqlite(
        jsonlPath: '${dir.path}/events.jsonl',
        log: TinaEntryLog.attach(db),
        entries: entries,
      );

      // A reader that persisted only "I saw up to rowid N" and the file
      // continues exactly where the log's rowids say it should.
      final mid = log.readAll()[2].id;
      final rest = log.since(mid);
      final fileTail = file.readAll().sublist(3);
      expect([for (final e in rest) e.payload], fileTail);

      db.close();
    });
  });

  group('the file itself', () {
    test('empty file and missing file read as empty', () {
      final missing = TinaJsonLinesFile('${dir.path}/nope.jsonl');
      expect(missing.readAll(), isEmpty);
      expect(missing.length, 0);

      File('${dir.path}/empty.jsonl').writeAsStringSync('');
      expect(TinaJsonLinesFile('${dir.path}/empty.jsonl').readAll(),
          isEmpty);
    });

    test('a truncated tail line surfaces as a FormatException', () {
      final file = TinaJsonLinesFile('${dir.path}/crash.jsonl');
      file.append({'a': 1});
      file.append({'b': 2});
      // A crash mid-append: the last line is half written.
      File(file.path).writeAsStringSync('{"a":1}\n{"b":', mode: FileMode.append);
      expect(() => file.readAll(), throwsFormatException);
    });

    test('every line is valid JSON with no blank lines', () {
      final db = openTinaDatabase('${dir.path}/lines.db', schemaVersion: 1,
          migrate: (db) => createEntryLogTable(db));
      final swap = swapJsonLinesWithSqlite(
        jsonlPath: '${dir.path}/events.jsonl',
        log: TinaEntryLog.attach(db),
        entries: batch(),
      );
      final path = swap.file.path;
      final text = File(path).readAsStringSync();
      expect(text.endsWith('\n'), isTrue);
      final lines = const LineSplitter().convert(text);
      expect(lines, hasLength(swap.log.length));
      for (final line in lines) {
        expect(jsonDecode(line), isA<Map>());
      }
      db.close();
    });
  });
}
