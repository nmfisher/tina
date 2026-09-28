import 'dart:async';
import 'package:classifier/exploration.dart';
import 'package:classifier/judgments.dart';
import 'package:test/test.dart';
import 'helpers.dart';

void main() {
  test(
    'auto handoff threshold is configurable without pruning verification',
    () async {
      final source = Source([const ProjectEvidence('a.dart', 'code')]);
      final judge = Judge()
        ..metadataHandler = (r, _) async => ranked(r, (_) => 0.85);
      final result = await ExplorationWorkflow(
        source: source,
        runner: batch(judge),
        selectionThreshold: 0.8,
      ).run('code');
      expect(result.stopReason, 'candidate_handoff');
      expect(judge.contentRequests, isEmpty);
    },
  );

  test(
    'one compact manifest includes deeply nested files without directory gates',
    () async {
      final source = Source([
        const ProjectEvidence('docs/guide.md', 'docs'),
        const ProjectEvidence(
          'packages/engine/lib/src/agent/cancel.dart',
          'stopTool();',
        ),
      ]);
      final judge = Judge()
        ..metadataHandler = (r, _) async {
          expect(source.reads, isEmpty);
          expect((r.state.value as Map)['manifest_scope'], 'whole_project');
          expect(
            manifest(r).values,
            contains('packages/engine/lib/src/agent/cancel.dart'),
          );
          return ranked(r, (path) => path.endsWith('cancel.dart') ? 0.95 : 0.1);
        };
      final result = await workflow(source, judge).run('cancellation');
      expect(judge.metadataRequests, hasLength(1));
      expect(judge.contentRequests, isEmpty);
      expect(source.reads.single, [
        'packages/engine/lib/src/agent/cancel.dart',
      ]);
      expect(result.stopReason, 'candidate_handoff');
      expect(result.files.single.unverifiedExcerpt!.text, 'stopTool();');
      expect(result.files.single.regions, isEmpty);
      expect(result.firstEvidenceMs, isNotNull);
    },
  );

  test(
    'manifest pages fit context and run concurrently with stable IDs',
    () async {
      final budget = JudgmentRequestBudget(
        maxInputTokens: 1800,
        overheadTokens: 100,
      );
      var active = 0;
      var peak = 0;
      final judge = Judge();
      judge.metadataHandler = (r, _) async {
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        active--;
        return judge.answer(r);
      };
      final tree = ProjectTree(
        List.generate(80, (i) => 'packages/p$i/lib/src/file.dart'),
        [],
      );
      final result = await RepositoryRanker(
        batch(judge, budget: budget),
      ).run(tree, 'cancellation', JudgmentCancellation(), (_) {});
      expect(peak, 2);
      expect(result.complete, isTrue);
      expect(result.files, hasLength(80));
      final ids = <String>{};
      for (final r in judge.requests) {
        expect(budget.check(r), lessThanOrEqualTo(1800));
        expect(ids.intersection(manifest(r).keys.toSet()), isEmpty);
        ids.addAll(manifest(r).keys);
      }
      expect(ids, hasLength(80));
    },
  );

  test('rank mode reads no bodies and bounds the main-agent handoff', () async {
    final source = Source(
      List.generate(50, (i) => ProjectEvidence('f$i.dart', 'code')),
    );
    final result = await workflow(
      source,
      Judge(),
    ).run('code', mode: ExplorationMode.rank);
    expect(source.reads, isEmpty);
    expect(result.contentRequests, 0);
    expect(result.toJson()['candidates'], hasLength(8));
    expect(result.ranking.files, hasLength(50));
  });

  test('first useful wave stops reading the remaining repository', () async {
    final source = Source(
      List.generate(
        80,
        (i) => ProjectEvidence('f${i.toString().padLeft(2, '0')}.dart', 'code'),
      ),
    );
    final judge = Judge();
    final result = await workflow(
      source,
      judge,
    ).run('code', mode: ExplorationMode.verify);
    expect(result.stopReason, 'enough_evidence');
    expect(source.reads, hasLength(2));
    expect(judge.contentRequests, hasLength(2));
    expect(result.files.first.regions.single.excerpt!.text, 'code');
    expect((result.toJson()['coverage'] as Map)['files_deferred'], 78);
  });

  test(
    'inconclusive waves expand to low filename scores rather than pruning',
    () async {
      final source = Source(
        List.generate(5, (i) => ProjectEvidence('f$i.dart', 'code')),
      );
      final judge = Judge()
        ..metadataHandler = (r, _) async =>
            ranked(r, (path) => path == 'f4.dart' ? 0.1 : 0.7);
      judge.handler = (r, _) async => judge.answer(
        r,
        probability: (r.state.value as Map)['path'] == 'f4.dart' ? 0.95 : 0.1,
      );
      final result = await workflow(source, judge).run('code');
      expect(result.stopReason, 'enough_evidence');
      expect(source.reads, hasLength(5));
      expect(result.files.last.regions.single.excerpt, isNotNull);
    },
  );

  test(
    'large files split into concurrent requests and return a matching region',
    () async {
      final budget = JudgmentRequestBudget(
        maxInputTokens: 1800,
        overheadTokens: 100,
      );
      final text = 'x' * 1700 + '\nCANCEL_HERE();\n';
      final source = Source([ProjectEvidence('big.dart', text)]);
      final judge = Judge();
      var active = 0;
      var peak = 0;
      judge.handler = (r, _) async {
        active++;
        if (active > peak) peak = active;
        await Future<void>.delayed(const Duration(milliseconds: 1));
        active--;
        return judge.answer(
          r,
          probability:
              ((r.state.value as Map)['content'] as String).contains(
                'CANCEL_HERE',
              )
              ? 0.95
              : 0.1,
        );
      };
      final result = await ExplorationWorkflow(
        source: source,
        runner: batch(judge, budget: budget),
      ).run('cancellation', mode: ExplorationMode.verify);
      expect(judge.contentRequests, hasLength(2));
      expect(peak, 2);
      expect(result.files.single.chunksTotal, 2);
      final region = result.files.single.regions.singleWhere(
        (r) => r.excerpt != null,
      );
      expect(region.excerpt!.text, contains('CANCEL_HERE'));
      expect(region.endLine, 2);
      expect(result.stopReason, 'enough_evidence');
    },
  );

  test(
    'chunking covers Unicode, boundaries and long lines without losing text',
    () {
      final budget = JudgmentRequestBudget(
        maxInputTokens: 1700,
        overheadTokens: 100,
      );
      for (final text in [
        '',
        '👋' * 700,
        'void f() {\n  stop(); // 汉字👋\n}\n\n' * 100,
      ]) {
        final chunks = FileChunker(
          budget,
        ).split(ProjectEvidence('a.dart', text), 'cancel');
        final runes = text.runes.toList();
        var covered = 0;
        for (final c in chunks) {
          expect(c.startScalar, lessThanOrEqualTo(covered));
          expect(
            c.text,
            String.fromCharCodes(runes.sublist(c.startScalar, c.endScalar)),
          );
          expect(
            c.startLine,
            1 + runes.take(c.startScalar).where((r) => r == 10).length,
          );
          expect(budget.check(c.request), lessThanOrEqualTo(1700));
          covered = c.endScalar;
        }
        expect(covered, runes.length);
      }
    },
  );

  test('run read budget is shared across successive content waves', () async {
    final source = Source(
      List.generate(5, (i) => ProjectEvidence('f$i.dart', 'x' * 10)),
    );
    final judge = Judge();
    judge.handler = (r, _) async => judge.answer(r, probability: 0.1);
    final result = await ExplorationWorkflow(
      source: source,
      runner: batch(judge),
      maxReadBytes: 20,
    ).run('code', mode: ExplorationMode.verify);
    expect(source.allowances, [20, 10]);
    expect(result.stopReason, 'read_budget');
    expect(result.status, 'partial');
  });

  test(
    'content budget refusal preserves ranked paths and does not send bodies',
    () async {
      final judge = Judge();
      final result = await workflow(
        Source([const ProjectEvidence('a.dart', 'code')]),
        judge,
        tokens: 1,
      ).run('code', mode: ExplorationMode.verify);
      expect(result.status, 'partial');
      expect(judge.contentRequests, isEmpty);
      expect(
        result.files.single.regions.single.failure,
        JudgmentFailure.budgetExceeded,
      );
    },
  );

  test('cancellation during ranking starts no file reads', () async {
    final source = Source([const ProjectEvidence('a.dart', 'code')]);
    final entered = Completer<void>();
    final stop = JudgmentCancellation();
    final judge = Judge()
      ..metadataHandler = (r, c) {
        entered.complete();
        final pending = Completer<JudgmentResult>();
        c!.listen(
          () => pending.completeError(
            const JudgmentException(JudgmentFailure.cancelled),
          ),
        );
        return pending.future;
      };
    final pending = workflow(source, judge).run('code', cancellation: stop);
    await entered.future;
    stop.cancel();
    expect((await pending).status, 'cancelled');
    expect(source.reads, isEmpty);
  });

  test('whole-workflow deadline settles a stalled evidence adapter', () async {
    final result = await workflow(
      _StalledSource(),
      Judge(),
      timeout: const Duration(milliseconds: 10),
    ).run('code');
    expect(result.status, 'timeout');
  });
}

class _StalledSource implements ProjectEvidenceSource {
  @override
  Future<ProjectTree> enumerate(
    JudgmentCancellation c,
    void Function(String) progress,
  ) => Completer<ProjectTree>().future;
  @override
  Future<EvidenceScan> read(
    List<String> paths,
    JudgmentCancellation c,
    void Function(String) progress, {
    int? maxBytes,
  }) => throw StateError('Unexpected read');
}
