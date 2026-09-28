import 'dart:async';
import 'dart:convert';
import 'package:classifier/exploration.dart';
import 'package:classifier/judgments.dart';
import 'package:test/test.dart';
import 'helpers.dart';

class MemoryCache implements ExplorationCache {
  final records = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>?> read(String key) async => records[key];
  @override
  Future<void> write(String key, Map<String, dynamic> record) async {
    records[key] = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(record)) as Map,
    );
  }
}

ExplorationWorkflow cached(
  Source source,
  Judge judge,
  ExplorationCache cache, {
  int tokens = 100000,
  String endpoint = 'endpoint',
  JudgmentRequestBudget? budget,
}) => ExplorationWorkflow(
  source: source,
  runner: batch(judge, tokens: tokens, budget: budget),
  cache: cache,
  cacheEndpoint: endpoint,
);

void main() {
  test('execution limits do not invalidate completed answers', () async {
    final cache = MemoryCache();
    final source = Source([const ProjectEvidence('a.dart', 'code')]);
    await cached(
      source,
      Judge(),
      cache,
    ).run('cancel?', mode: ExplorationMode.verify);
    final judge = Judge();
    final result = await ExplorationWorkflow(
      source: source,
      cache: cache,
      cacheEndpoint: 'endpoint',
      timeout: const Duration(seconds: 30),
      maxReadBytes: 100,
      runner: JudgmentBatchRunner(
        service: judge,
        budget: JudgmentRequestBudget(
          maxInputTokens: 2000,
          overheadTokens: 100,
        ),
        limits: JudgmentBatchLimits(
          concurrency: 1,
          maxRequests: 1,
          maxChargedTokens: 1,
          outputTokenAllowance: 1,
          timeout: const Duration(seconds: 20),
          requestTimeout: const Duration(seconds: 10),
        ),
      ),
    ).run('cancel?', mode: ExplorationMode.verify);
    expect(result.answerCacheHit, isTrue);
    expect(judge.requests, isEmpty);
    expect(result.chargedTokens, 0);
  });

  test('model changes invalidate answers and individual judgments', () async {
    final cache = MemoryCache();
    final source = Source([const ProjectEvidence('a.dart', 'code')]);
    await cached(
      source,
      Judge(),
      cache,
    ).run('cancel?', mode: ExplorationMode.verify);
    final judge = Judge();
    final result = await cached(
      source,
      judge,
      cache,
      budget: JudgmentRequestBudget(model: 'another-model'),
    ).run('cancel?', mode: ExplorationMode.verify);
    expect(result.answerCacheHit, isFalse);
    expect(judge.requests, hasLength(2));
  });

  test('editing another chunk preserves identical content requests', () async {
    final cache = MemoryCache();
    final text = List.generate(400, (i) => 'line $i: source code\n').join();
    final source = Source([ProjectEvidence('large.dart', text)]);
    final budget = JudgmentRequestBudget(
      maxInputTokens: 2000,
      overheadTokens: 100,
    );
    final first = Judge();
    first.handler = (r, _) async => first.answer(r, probability: 0.1);
    await cached(
      source,
      first,
      cache,
      budget: budget,
    ).run('cancel?', mode: ExplorationMode.verify);
    expect(first.contentRequests.length, greaterThan(2));
    source.evidence[0] = ProjectEvidence(
      'large.dart',
      text.replaceFirst('line 399', 'edit 399'),
    );
    final next = Judge();
    next.handler = (r, _) async => next.answer(r, probability: 0.1);
    final result = await cached(
      source,
      next,
      cache,
      budget: budget,
    ).run('cancel?', mode: ExplorationMode.verify);
    expect(result.answerCacheHit, isFalse);
    expect(result.contentCacheHits, greaterThan(0));
    expect(next.contentRequests, isNotEmpty);
    expect(next.contentRequests.length, lessThan(first.contentRequests.length));
    expect(
      next.contentRequests.every(
        (r) =>
            ((r.state.value as Map)['content'] as String).contains('edit 399'),
      ),
      isTrue,
    );
  });

  test(
    'editing another manifest page preserves identical ranking requests',
    () async {
      final cache = MemoryCache();
      final paths = List.generate(
        100,
        (i) => 'src/file_${i.toString().padLeft(3, '0')}.dart',
      );
      final budget = JudgmentRequestBudget(
        maxInputTokens: 2000,
        overheadTokens: 100,
      );
      Future<RankingResult> rank(Judge judge) =>
          RepositoryRanker(batch(judge, budget: budget)).run(
            ProjectTree(paths, []),
            'cancel?',
            JudgmentCancellation(),
            (_) {},
            cache: ExplorationCacheSession(
              store: cache,
              endpoint: 'endpoint',
              cancellation: JudgmentCancellation(),
            ),
          );
      final first = Judge();
      await rank(first);
      expect(first.metadataRequests.length, greaterThan(2));
      paths[99] = 'src/file_zzz.dart';
      final next = Judge();
      final result = await rank(next);
      expect(result.complete, isTrue);
      expect(next.metadataRequests, hasLength(1));
      expect(result.cacheHits, first.metadataRequests.length - 1);
    },
  );

  for (final rename in [false, true]) {
    test(
      '${rename ? "renaming" : "deleting"} a file invalidates the manifest',
      () async {
        final cache = MemoryCache();
        final source = Source([
          const ProjectEvidence('a.dart', 'code'),
          const ProjectEvidence('b.dart', 'code'),
        ]);
        await cached(
          source,
          Judge(),
          cache,
        ).run('cancel?', mode: ExplorationMode.verify);
        if (rename) {
          source.evidence[0] = const ProjectEvidence('renamed.dart', 'code');
        } else {
          source.evidence.removeAt(0);
        }
        final judge = Judge();
        final result = await cached(
          source,
          judge,
          cache,
        ).run('cancel?', mode: ExplorationMode.verify);
        expect(result.answerCacheHit, isFalse);
        expect(judge.metadataRequests, hasLength(1));
        expect(judge.contentRequests, hasLength(rename ? 1 : 0));
        expect(result.files.any((f) => f.path == 'a.dart'), isFalse);
      },
    );
  }
  test('cache IO failure leaves exploration usable', () async {
    final source = Source([const ProjectEvidence('a.dart', 'code')]);
    final judge = Judge();
    final result = await cached(
      source,
      judge,
      _UnavailableCache(),
    ).run('cancel?', mode: ExplorationMode.verify);
    expect(result.status, 'completed');
    expect(judge.requests, hasLength(2));
  });
  test('cancelling answer validation stops before any API request', () async {
    final cache = MemoryCache();
    final source = Source([const ProjectEvidence('a.dart', 'code')]);
    await cached(
      source,
      Judge(),
      cache,
    ).run('cancel?', mode: ExplorationMode.verify);
    final stalled = _StalledRead(source.evidence);
    final judge = Judge();
    final stop = JudgmentCancellation();
    final pending = cached(
      stalled,
      judge,
      cache,
    ).run('cancel?', mode: ExplorationMode.verify, cancellation: stop);
    await stalled.entered.future;
    stop.cancel();
    final result = await pending;
    expect(result.status, 'cancelled');
    expect(judge.requests, isEmpty);
  });

  test(
    'completed answers survive a new workflow with zero API spend',
    () async {
      final cache = MemoryCache();
      final source = Source([
        const ProjectEvidence('a.dart', 'negative'),
        const ProjectEvidence('b.dart', 'match'),
      ]);
      final judge = Judge();
      judge.handler = (r, _) async => judge.answer(
        r,
        probability: (r.state.value as Map)['path'] == 'a.dart' ? 0.1 : 0.95,
      );
      final first = await cached(
        source,
        judge,
        cache,
      ).run('cancel?', mode: ExplorationMode.verify);
      expect(judge.requests, hasLength(3));
      final again = Judge();
      final second = await cached(
        source,
        again,
        cache,
      ).run('cancel?', mode: ExplorationMode.verify);
      expect(second.answerCacheHit, isTrue);
      expect(again.requests, isEmpty);
      expect(second.chargedTokens, 0);
      expect(second.inputTokens, 0);
      expect(second.outputTokens, 0);
      expect(
        second.files.last.regions.single.excerpt!.text,
        first.files.last.regions.single.excerpt!.text,
      );
      expect(source.reads.last, [
        'a.dart',
        'b.dart',
      ]); // Includes the negative match.
    },
  );

  test(
    'same-length edits to negative evidence invalidate the answer, not ranking',
    () async {
      final cache = MemoryCache();
      final source = Source([
        const ProjectEvidence('a.dart', 'old'),
        const ProjectEvidence('b.dart', 'yes'),
      ]);
      final first = Judge();
      first.handler = (r, _) async => first.answer(
        r,
        probability: (r.state.value as Map)['path'] == 'a.dart' ? 0.1 : 0.95,
      );
      await cached(
        source,
        first,
        cache,
      ).run('cancel?', mode: ExplorationMode.verify);
      source.evidence[0] = const ProjectEvidence('a.dart', 'new');
      final judge = Judge();
      final result = await cached(
        source,
        judge,
        cache,
      ).run('cancel?', mode: ExplorationMode.verify);
      expect(result.answerCacheHit, isFalse);
      expect(judge.metadataRequests, isEmpty);
      expect(judge.contentRequests, hasLength(1));
      expect(
        (judge.contentRequests.single.state.value as Map)['content'],
        'new',
      );
      expect(result.contentCacheHits, 1);
    },
  );

  test(
    'adding a file reranks names but reuses unchanged content judgments',
    () async {
      final cache = MemoryCache();
      final source = Source([
        const ProjectEvidence('a.dart', 'a'),
        const ProjectEvidence('b.dart', 'b'),
      ]);
      await cached(
        source,
        Judge(),
        cache,
      ).run('cancel?', mode: ExplorationMode.verify);
      source.evidence.add(const ProjectEvidence('new.dart', 'new'));
      final judge = Judge()
        ..metadataHandler = (r, _) async =>
            ranked(r, (path) => path == 'new.dart' ? 0.99 : 0.7);
      final result = await cached(
        source,
        judge,
        cache,
      ).run('cancel?', mode: ExplorationMode.verify);
      expect(judge.metadataRequests, hasLength(1));
      expect(judge.contentRequests, hasLength(1));
      expect(
        (judge.contentRequests.single.state.value as Map)['path'],
        'new.dart',
      );
      expect(result.contentCacheHits, 1);
    },
  );

  test(
    'answer hits bypass a smaller API budget and retain zero usage',
    () async {
      final cache = MemoryCache();
      final source = Source([const ProjectEvidence('a.dart', 'code')]);
      await cached(
        source,
        Judge(),
        cache,
      ).run('cancel?', mode: ExplorationMode.verify);
      final judge = Judge();
      final result = await cached(
        source,
        judge,
        cache,
        tokens: 1,
      ).run('cancel?', mode: ExplorationMode.verify);
      expect(result.answerCacheHit, isTrue);
      expect(result.ranking.cacheHits, 1);
      expect(result.contentCacheHits, 1);
      expect(result.stopReason, 'enough_evidence');
      expect(judge.requests, isEmpty);
      expect(result.chargedTokens, 0);
      expect(result.inputTokens, 0);
    },
  );

  test(
    'old answers and judgments remain reusable; refresh forces new judgments',
    () async {
      final cache = MemoryCache();
      final source = Source([const ProjectEvidence('a.dart', 'code')]);
      await cached(
        source,
        Judge(),
        cache,
      ).run('cancel?', mode: ExplorationMode.verify);
      for (final record in cache.records.values) {
        expect(record, isNot(contains('expires_at')));
        // Legacy timestamps must not invalidate otherwise matching evidence.
        record['created_at'] = '2000-01-01T00:00:00.000Z';
        record['expires_at'] = '2000-01-02T00:00:00.000Z';
      }
      final before = Judge();
      expect(
        (await cached(
          source,
          before,
          cache,
        ).run('cancel?', mode: ExplorationMode.verify)).answerCacheHit,
        isTrue,
      );
      expect(before.requests, isEmpty);
      final reused = Judge();
      final result = await cached(
        source,
        reused,
        cache,
        tokens: 1,
      ).run('cancel?', mode: ExplorationMode.verify, maxResults: 2);
      expect(result.answerCacheHit, isFalse);
      expect(result.ranking.cacheHits, 1);
      expect(result.contentCacheHits, 1);
      expect(reused.requests, isEmpty);
      final refresh = Judge();
      await cached(
        source,
        refresh,
        cache,
      ).run('cancel?', mode: ExplorationMode.verify, refresh: true);
      expect(refresh.requests, hasLength(2));
    },
  );

  test('question and endpoint changes miss independently', () async {
    final cache = MemoryCache();
    final source = Source([const ProjectEvidence('a.dart', 'code')]);
    await cached(
      source,
      Judge(),
      cache,
    ).run('cancel?', mode: ExplorationMode.verify);
    for (final entry in [('Cancel?', 'endpoint'), ('cancel?', 'other')]) {
      final judge = Judge();
      await cached(
        source,
        judge,
        cache,
        endpoint: entry.$2,
      ).run(entry.$1, mode: ExplorationMode.verify);
      expect(judge.requests, hasLength(2));
    }
  });

  test(
    'partial failures are retried while successful judgments survive',
    () async {
      final cache = MemoryCache();
      final source = Source([const ProjectEvidence('a.dart', 'code')]);
      final first = Judge()
        ..handler = (r, _) async =>
            throw const JudgmentException(JudgmentFailure.unavailable);
      final failed = await cached(
        source,
        first,
        cache,
      ).run('cancel?', mode: ExplorationMode.verify);
      expect(failed.status, 'partial');
      final next = Judge();
      final result = await cached(
        source,
        next,
        cache,
      ).run('cancel?', mode: ExplorationMode.verify);
      expect(result.answerCacheHit, isFalse);
      expect(next.metadataRequests, isEmpty);
      expect(next.contentRequests, hasLength(1));
    },
  );

  test('corrupt records are misses, not fatal errors', () async {
    final cache = MemoryCache();
    final source = Source([const ProjectEvidence('a.dart', 'code')]);
    await cached(
      source,
      Judge(),
      cache,
    ).run('cancel?', mode: ExplorationMode.verify);
    for (final record in cache.records.values) {
      record['payload_hash'] = 'corrupt';
    }
    final judge = Judge();
    final result = await cached(
      source,
      judge,
      cache,
    ).run('cancel?', mode: ExplorationMode.verify);
    expect(result.status, 'completed');
    expect(judge.requests, hasLength(2));
  });

  test(
    'rank and auto snapshots preserve their distinct evidence semantics',
    () async {
      final cache = MemoryCache();
      final source = Source([const ProjectEvidence('a.dart', 'code')]);
      final judge = Judge()
        ..metadataHandler = (r, _) async => ranked(r, (_) => 0.99);
      await cached(
        source,
        judge,
        cache,
      ).run('cancel?', mode: ExplorationMode.rank);
      final rank = await cached(
        source,
        Judge(),
        cache,
      ).run('cancel?', mode: ExplorationMode.rank);
      expect(rank.answerCacheHit, isTrue);
      expect(source.reads, isEmpty);
      final auto = await cached(source, Judge(), cache).run('cancel?');
      expect(auto.stopReason, 'candidate_handoff');
      final replay = await cached(source, Judge(), cache).run('cancel?');
      expect(replay.answerCacheHit, isTrue);
      expect(replay.files.single.unverifiedExcerpt!.text, 'code');
      expect(replay.files.single.regions, isEmpty);
    },
  );
}

class _UnavailableCache implements ExplorationCache {
  @override
  Future<Map<String, dynamic>?> read(String key) async =>
      throw StateError('unavailable');
  @override
  Future<void> write(String key, Map<String, dynamic> record) async =>
      throw StateError('unavailable');
}

class _StalledRead extends Source {
  final entered = Completer<void>();
  _StalledRead(super.evidence);
  @override
  Future<EvidenceScan> read(
    List<String> paths,
    JudgmentCancellation c,
    void Function(String) progress, {
    int? maxBytes,
  }) {
    if (!entered.isCompleted) entered.complete();
    return Completer<EvidenceScan>().future;
  }
}
