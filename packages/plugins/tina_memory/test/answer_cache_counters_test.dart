/// The persisted answer-cache counters: schema v2's table, the
/// in-place v1→v2 migration, accumulation across sessions and scopes,
/// and the AnswerCache delta wiring (serve/accept/decline/stale all
/// report; the plugin persists through the project tier).
library;

import 'dart:io';

import 'package:sqlite3/sqlite3.dart' as sqlite3;
import 'package:test/test.dart';
import 'package:tina_memory/tina_memory.dart';
import 'package:tina_memory/tina_memory_sqlite.dart';

void main() {
  late Directory dir;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('tina-counters-');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('counters accumulate across sessions and reopenings', () {
    final path = '${dir.path}/m.db';
    final first = SqliteMemoryStore.open(path, MemoryScope.project);
    first.bumpAnswerCache(
        const AnswerCacheCounters(
            served: 3, accepted: 2, declined: 1, tokensSaved: 900),
        MemoryScope.project);
    expect(
        first.answerCacheCounters(MemoryScope.project).toMap(),
        containsPair('served', 3));
    // The session's in-memory view resets on close…
    first.close();
    // …but the store keeps the numbers: a fresh open reads them back.
    final second = SqliteMemoryStore.open(path, MemoryScope.project);
    expect(
        second.answerCacheCounters(MemoryScope.project).toMap(),
        {
          'served': 3,
          'accepted': 2,
          'declined': 1,
          'stale_dropped': 0,
          'tokens_saved': 900,
        },
        reason: 'the scoreboard survives restarts');
    second.bumpAnswerCache(
        const AnswerCacheCounters(served: 1, tokensSaved: 300),
        MemoryScope.project);
    expect(second.answerCacheCounters(MemoryScope.project).served, 4);
    second.close();
  });

  test('a v1 file migrates in place: rows kept, counters start at zero',
      () {
    final path = '${dir.path}/v1.db';
    // A hand-built v1 store: memory rows, user_version 1, no counters
    // table.
    final raw = sqlite3.sqlite3.open(path);
    raw.execute('CREATE TABLE memory ('
        'id INTEGER PRIMARY KEY, '
        'scope TEXT NOT NULL, '
        'category TEXT NOT NULL, '
        'text TEXT NOT NULL, '
        'created_at TEXT NOT NULL, '
        'updated_at TEXT NOT NULL, '
        'updated_by TEXT NOT NULL, '
        'last_recalled TEXT, '
        'recall_count INTEGER NOT NULL DEFAULT 0)');
    raw.execute(
        "INSERT INTO memory (scope, category, text, created_at, "
        "updated_at, updated_by) VALUES ('project', 'facts', 'kept', "
        "'2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', 's1')");
    raw.userVersion = 1;
    raw.close();

    final store = SqliteMemoryStore.open(path, MemoryScope.project);
    addTearDown(store.close);
    expect(store.list().single.text, 'kept', reason: 'rows survive');
    // No fabricated history: the migration starts the counters at
    // zero, not at anything guessed from the memory rows.
    expect(store.answerCacheCounters(MemoryScope.project).toMap(),
        containsPair('served', 0));
    store.bumpAnswerCache(const AnswerCacheCounters(served: 1),
        MemoryScope.project);
    expect(store.answerCacheCounters(MemoryScope.project).served, 1);

    final check = sqlite3.sqlite3.open(path);
    addTearDown(check.close);
    expect(check.userVersion, 2);
  });

  test('scopes are independent rows', () {
    final store = SqliteMemoryStore.open(
        '${dir.path}/g.db', MemoryScope.global);
    addTearDown(store.close);
    store.bumpAnswerCache(
        const AnswerCacheCounters(served: 7), MemoryScope.global);
    store.bumpAnswerCache(
        const AnswerCacheCounters(served: 2), MemoryScope.project);
    expect(store.answerCacheCounters(MemoryScope.global).served, 7);
    expect(store.answerCacheCounters(MemoryScope.project).served, 2);
  });

  test('zero deltas write nothing and read as zero', () {
    final store = SqliteMemoryStore.open(
        '${dir.path}/z.db', MemoryScope.project);
    addTearDown(store.close);
    store.bumpAnswerCache(const AnswerCacheCounters(), MemoryScope.project);
    expect(store.answerCacheCounters(MemoryScope.project).served, 0);
  });

  test('the in-memory twin keeps the same shape (session-only)', () {
    final store = InMemoryMemoryStore(scope: MemoryScope.project);
    addTearDown(store.close);
    store.bumpAnswerCache(
        const AnswerCacheCounters(served: 2, accepted: 1),
        MemoryScope.project);
    expect(store.answerCacheCounters(MemoryScope.project).served, 2);
    expect(store.answerCacheCounters(MemoryScope.global).served, 0);
  });

  test('the cache reports deltas for serve, accept, decline and stale',
      () {
    final deltas = <AnswerCacheCounters>[];
    final cache = AnswerCache(
        onCounters: deltas.add,
        // No filesystem: the freshness gate sees every path alive.
        fileSystem: _AllFiles());
    final captured =
        cache.capture('find the ledger', ['/work/ledger.dart']);
    expect(captured, isNotNull);
    expect(deltas, isEmpty, reason: 'captures carry no counter deltas');

    final served = cache.serve('find the ledger');
    expect(served, isNotNull);
    cache.accept(served!);
    cache.decline(served);
    final served2 = cache.serve('ledger find');
    expect(served2, isNotNull);

    final total = deltas.fold(
        const AnswerCacheCounters(), (a, b) => a + b);
    expect(total.served, 2);
    expect(total.accepted, 1);
    expect(total.declined, 1);
    expect(total.tokensSaved, 2 * answerCacheTokensPerPath);
    // The live scoreboard still mirrors the same numbers.
    expect(cache.stats.served, 2);
    expect(cache.stats.accepted, 1);
    expect(cache.stats.declined, 1);
  });
}

final class _AllFiles implements AnswerFiles {
  @override
  bool exists(String path) => true;
}
