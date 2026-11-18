import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:test/test.dart';
import 'package:tina_memory/tina_memory.dart'
    hide openDefaultMemoryStores;
import 'package:tina_memory/tina_memory_sqlite.dart';
import 'package:tina_sqlite/tina_sqlite.dart';

/// The store layer: schema, revision guard, heat semantics, origin
/// keying and the in-memory twin's parity. Both implementations run
/// every behavioral case (the parity contract the wasm engine will
/// lean on).
void main() {
  for (final kind in ['sqlite', 'in-memory']) {
    group(kind, () {
      late MemoryStoreApi store;
      setUp(() {
        store = kind == 'sqlite'
            ? SqliteMemoryStore.open(':memory:', MemoryScope.project)
            : InMemoryMemoryStore();
      });
      tearDown(() => store.close());

      test('remember fills id and stamps identity', () {
        final entry = store.remember('tests live in test/',
            category: MemoryCategory.paths, updatedBy: 's1');
        expect(entry.id, greaterThan(0));
        expect(entry.category, MemoryCategory.paths);
        expect(entry.updatedBy, 's1');
        expect(entry.createdAt, entry.updatedAt);
        expect(entry.recallCount, 0);
      });

      test('recall matches every term, case-insensitively, and bumps '
          'heat durably', () {
        store.remember('the widget builder lives in lib/widgets.dart',
            category: MemoryCategory.paths, updatedBy: 's1');
        store.remember('unrelated note about release process',
            category: MemoryCategory.facts, updatedBy: 's1');
        final hit =
            store.recall('WIDGET builder').single;
        expect(hit.text, contains('lib/widgets.dart'));
        // Bumped durably: a fresh read sees the heat.
        expect(store.entry(hit.id)!.recallCount, 1);
        expect(store.entry(hit.id)!.lastRecalled, isNotNull);
        store.recall('widget');
        expect(store.entry(hit.id)!.recallCount, 2);
        // Multi-term is a conjunction: a partial match serves nothing.
        expect(store.recall('widget builder zzz'), isEmpty);
      });

      test('the revision guard returns the current text on conflict',
          () {
        final entry = store.remember('v1: use LIKE search',
            category: MemoryCategory.decisions, updatedBy: 's1');
        // Another session revises first.
        store.revise(entry.id, 'v2: use FTS search',
            expected: entry.updatedAt, updatedBy: 's2');
        // Our stale revise conflicts: current text comes back.
        expect(
          () => store.revise(entry.id, 'v1.5: LIKE is fine',
              expected: entry.updatedAt, updatedBy: 's1'),
          throwsA(isA<MemoryRevisionConflict>()
              .having((e) => e.current.text, 'text', contains('v2'))),
        );
      });

      test('forget deletes and is idempotent', () {
        final entry = store.remember('gone soon',
            category: MemoryCategory.facts, updatedBy: 's1');
        expect(store.forget(entry.id)!.id, entry.id);
        expect(store.forget(entry.id), isNull);
        expect(store.entry(entry.id), isNull);
      });

      test('hottest ranks by recall count then recency', () {
        final cold = store.remember('never recalled',
            category: MemoryCategory.facts, updatedBy: 's1');
        final warm = store.remember('recalled once',
            category: MemoryCategory.facts, updatedBy: 's1');
        store.recall('recalled once');
        final hot = store.remember('recalled lots',
            category: MemoryCategory.facts, updatedBy: 's1');
        store.recall('recalled lots');
        store.recall('recalled lots');
        final ranked = store.hottest();
        expect(ranked.first.id, hot.id);
        expect(ranked[1].id, warm.id);
        expect(ranked.last.id, cold.id);
      });
    });
  }

  group('origin keying', () {
    test('URL shapes collapse to one key', () {
      expect(normalizeRepoOrigin('https://github.com/o/r.git'),
          normalizeRepoOrigin('git@github.com:o/r'));
      expect(normalizeRepoOrigin('ssh://git@github.com/o/r'),
          normalizeRepoOrigin('https://github.com/o/r.git'));
      expect(normalizeRepoOrigin('https://github.com/o/r'),
          'github.com/o/r');
      expect(normalizeRepoOrigin('https://GitHub.com/O/R.git'),
          isNot(normalizeRepoOrigin('https://github.com/o/other')));
      expect(() => normalizeRepoOrigin(''),
          throwsFormatException);
      expect(() => normalizeRepoOrigin('not-a-url'),
          throwsFormatException);
    });

    test('two checkouts of one origin share the repo file', () {
      final home = Directory.systemTemp.createTempSync('tina-mem-key');
      addTearDown(() => home.deleteSync(recursive: true));
      final one = gitCheckout(home, 'one', 'https://github.com/team/proj.git');
      final two = gitCheckout(home, 'two', 'git@github.com:team/proj.git');
      final storesOne = openDefaultMemoryStores(one,
          environment: {'HOME': home.path});
      final storesTwo = openDefaultMemoryStores(two,
          environment: {'HOME': home.path});
      addTearDown(storesOne.close);
      addTearDown(storesTwo.close);

      storesOne.project.remember('the store seam is in tina_memory',
          category: MemoryCategory.structure, updatedBy: 's1');
      final seen = storesTwo.project.recall('store seam');
      expect(seen, isNotEmpty,
          reason: 'different checkouts, one origin, one memory');

      // A different origin gets its own file.
      final other = gitCheckout(home, 'other', 'https://github.com/x/y.git');
      final storesOther = openDefaultMemoryStores(other,
          environment: {'HOME': home.path});
      addTearDown(storesOther.close);
      expect(storesOther.project.recall('store seam'), isEmpty);
    });

    test('a workspace with no origin never shares a repo file', () {
      final home = Directory.systemTemp.createTempSync('tina-mem-sandbox');
      addTearDown(() => home.deleteSync(recursive: true));
      final a = Directory('${home.path}/a')..createSync();
      final b = Directory('${home.path}/b')..createSync();
      final sa = openDefaultMemoryStores(a.path,
          environment: {'HOME': home.path});
      final sb = openDefaultMemoryStores(b.path,
          environment: {'HOME': home.path});
      addTearDown(sa.close);
      addTearDown(sb.close);
      sa.project.remember('private sandbox fact',
          category: MemoryCategory.facts, updatedBy: 's1');
      expect(sb.project.recall('private sandbox'), isEmpty);
    });
  });

  test('the sqlite file is WAL-mode with a busy timeout', () {
    final dir = Directory.systemTemp.createTempSync('tina-mem-wal');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/m.db';
    final store = SqliteMemoryStore.open(path, MemoryScope.project);
    store.remember('x', category: MemoryCategory.facts, updatedBy: 's');
    store.close();
    final raw = sqlite3.sqlite3.open(path);
    addTearDown(raw.close);
    expect(raw.select('PRAGMA journal_mode').single['journal_mode'], 'wal');
    // busy_timeout is per-connection (not a file setting), so a raw
    // second connection reads 0: assert it on a store-shaped open.
    final live = openTinaDatabase('${dir.path}/probe.db',
        schemaVersion: 1, migrate: (_) {});
    addTearDown(live.close);
    expect(live.select('PRAGMA busy_timeout').single['timeout'], 5000);
    expect(
      raw.select('SELECT COUNT(*) AS n FROM sqlite_master '
          "WHERE type='table' AND name='memory'").single['n'],
      1,
    );
  });
}

String gitCheckout(Directory parent, String name, String url) {
  final dir = Directory('${parent.path}/$name')..createSync();
  Process.runSync('git', ['init', '-q', '.'], workingDirectory: dir.path);
  Process.runSync('git', ['remote', 'add', 'origin', url],
      workingDirectory: dir.path);
  return dir.path;
}
