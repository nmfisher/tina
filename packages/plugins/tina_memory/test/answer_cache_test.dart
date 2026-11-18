import 'package:test/test.dart';
import 'package:tina_memory/tina_memory.dart';

/// The answer cache (L5): capture hygiene, precision matching, the
/// freshness gate, telemetry, and the durable mirror.
void main() {
  late Map<String, bool> disk;
  late AnswerCache cache;

  setUp(() {
    disk = {};
    cache = AnswerCache(fileSystem: _Disk(disk));
  });

  group('capture', () {
    test('captures query terms -> resolved paths', () {
      disk['lib/store.dart'] = true;
      final answer = cache.capture('find the store seam',
          ['lib/store.dart']);
      expect(answer, isNotNull);
      expect(answer!.terms, containsAll(['store', 'seam']),
          reason: 'content terms; stop words dropped');
      expect(answer.paths, ['lib/store.dart']);
    });

    test('secret-shaped queries and paths are never stored', () {
      expect(cache.capture('grep API_KEY= value', ['lib/a.dart']), isNull);
      expect(
          cache.capture('read the config',
              ['secrets/api_token.json', 'lib/a.dart']),
          isNull,
          reason: 'a secret path redacts the whole capture');
      expect(cache.capture('cat ~/.ssh/id_rsa', ['/home/u/.ssh/id_rsa']),
          isNull);
      expect(cache.answers, isEmpty);
    });

    test('huge and empty result sets are skipped', () {
      expect(cache.capture('q', []), isNull);
      expect(
          cache.capture('q', [for (var i = 0; i <= answerCacheMaxPaths; i++) 'p$i']),
          isNull);
    });

    test('recapture refreshes instead of duplicating', () {
      disk['a.dart'] = true;
      cache.capture('store seam', ['a.dart']);
      cache.capture('store seam', ['a.dart']);
      expect(cache.answers, hasLength(1));
      expect(cache.answers.single.paths, ['a.dart']);
    });

    test('the cache is bounded (capacity)', () {
      for (var i = 0; i < answerCacheCapacity + 10; i++) {
        cache.capture('query number $i', ['p$i.dart']);
      }
      expect(cache.answers.length, answerCacheCapacity);
      expect(cache.answers.last.terms, contains('${answerCacheCapacity + 9}'),
          reason: 'newest kept');
      expect(cache.answers.first.terms, contains('10'),
          reason: 'the oldest ten fell out');
    });
  });

  group('matching and the freshness gate', () {
    test('a differently-phrased query resolves from the cache', () {
      disk['lib/src/store.dart'] = true;
      cache.capture('where is the store implementation',
          ['lib/src/store.dart']);
      // Same intent, different phrasing, extra terms.
      final served =
          cache.serve('find the store implementation file please');
      expect(served, isNotNull);
      expect(served!.paths, ['lib/src/store.dart']);
      expect(cache.stats.served, 1);
    });

    test('a weak overlap does not serve (precision bar)', () {
      disk['a.dart'] = true;
      cache.capture('store seam location', ['a.dart']);
      expect(cache.serve('completely different topic'), isNull);
      expect(cache.serve('store'), isNull,
          reason: 'one shared term of three is below the bar');
      expect(cache.stats.served, 0);
    });

    test('a deleted path is pruned; a fully stale answer is dropped',
        () {
      disk['gone.dart'] = true;
      disk['kept.dart'] = true;
      cache.capture('the widgets', ['gone.dart', 'kept.dart']);
      disk.remove('gone.dart');
      final served = cache.serve('the widgets location');
      expect(served!.servedPaths, ['kept.dart'],
          reason: 'the stale pointer was pruned, not injected');
      expect(cache.stats.staleDropped, 1,
          reason: 'one stale pointer counted once');

      disk.remove('kept.dart');
      expect(cache.serve('the widgets location'), isNull,
          reason: 'nothing alive: answer dropped, search proceeds');
      expect(cache.answers, isEmpty);
      expect(cache.stats.staleDropped, 3,
          reason: '1 partial prune, then the final drop counts the '
              'whole master list (gone + kept)');
    });

    test('freshness is checked per serve, not just at capture', () {
      disk['a.dart'] = true;
      disk['b.dart'] = true;
      cache.capture('alpha', ['a.dart', 'b.dart']);
      disk.remove('a.dart');
      expect(cache.serve('alpha')!.servedPaths, ['b.dart'],
          reason: 'pruned at serve time (master list intact)');
      disk['a.dart'] = true; // recreated: the gate sees it again
      expect(cache.serve('alpha')!.servedPaths, contains('a.dart'),
          reason: 'the gate re-stats the master list on every serve');
      // A FULLY stale answer is dropped: the search proceeds.
      disk.remove('a.dart');
      disk.remove('b.dart');
      expect(cache.serve('alpha'), isNull);
      expect(cache.answers, isEmpty);
    });
  });

  group('telemetry and injection', () {
    test('served/accepted/declined and the token estimate', () {
      disk['a.dart'] = true;
      disk['b.dart'] = true;
      final answer = cache.capture('widget seam', ['a.dart', 'b.dart'])!;
      final served = cache.serve('widget seam layout')!;
      expect(answer, isNotNull);
      cache.accept(served);
      cache.decline(served);
      final stats = cache.stats;
      expect(stats.served, 1);
      expect(stats.accepted, 1);
      expect(stats.declined, 1);
      expect(stats.estimatedTokensSaved, answerCacheTokensPerPath);
    });

    test('the injection block labels, cites ids and says how to revise',
        () {
      disk['a.dart'] = true;
      cache.capture('widget seam layout', ['a.dart']);
      final served = cache.serve('widget seam layout')!;
      final block = cache.injectionBlock(served);
      expect(block, startsWith('<memory-answer-cache>'));
      expect(block, contains('a.dart'));
      expect(block, contains('revise or forget'));
    });
  });

  group('the durable mirror', () {
    test('capture persists a paths entry; injection cites it', () {
      final store = InMemoryMemoryStore();
      addTearDown(store.close);
      final durable = AnswerCache(persister: MemoryAnswerPersister(store),
          fileSystem: _Disk(disk));
      disk['lib/x.dart'] = true;
      final answer = durable.capture('the config loader', ['lib/x.dart']);
      expect(answer!.memoryEntryId, isNotNull);
      expect(store.list().single.category, MemoryCategory.paths);
      expect(store.list().single.text, contains('lib/x.dart'));
      final served = durable.serve('config loader location')!;
      expect(durable.injectionBlock(served), contains('#1'));
    });
  });
}

final class _Disk implements AnswerFiles {
  _Disk(this.map);
  final Map<String, bool> map;
  @override
  bool exists(String path) => map[path] ?? false;
}
