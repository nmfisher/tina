import 'dart:async';

import 'package:classifier/classification.dart';
import 'package:classifier/judgments.dart';
import 'package:test/test.dart';

import 'helpers.dart';

void main() {
  late MemoryStore store;
  late Executor executor;
  late MemorySource<int> source;
  ClassificationOrchestrator service({
    int concurrency = 3,
    int maxCalls = 128,
    Duration? timeout,
  }) => ClassificationOrchestrator(
    store: store,
    executor: executor,
    concurrency: concurrency,
    maxCalls: maxCalls,
    timeout: timeout ?? const Duration(seconds: 10),
  );
  setUp(() {
    store = MemoryStore();
    executor = Executor();
    source = MemorySource(numberContract, {
      'entity': [1, 2],
    });
  });

  test(
    'typed non-file source and non-label output restore without preparing inputs or model calls',
    () async {
      final first = await service().run((s) => s.classify(numberTask(source)));
      expect(first.result.value, 3);
      expect(source.snapshots, 1);
      executor.calls.clear();
      final second = await service().run(
        (s) => s.classify(numberTask(source)),
        restoreOnly: true,
      );
      expect(second.result.value, 3);
      expect(second.id, first.id);
      expect(source.snapshots, 1);
      expect(executor.calls, isEmpty);
    },
  );

  test(
    'source substitution and encoder revisions invalidate final and request records',
    () async {
      await service().run((s) => s.classify(numberTask(source)));
      final alternate = MemorySource(
        numberContract,
        source.subjects,
        identity: {'source': 'database', 'encoder': 2},
      );
      await service().run((s) => s.classify(numberTask(alternate)));
      expect(executor.calls, hasLength(2));
    },
  );

  test(
    'source-defined freshness detects content changes even when input IDs stay unchanged',
    () async {
      await service().run((s) => s.classify(numberTask(source)));
      source.subjects['entity'] = [4, 5];
      final result = await service().run((s) => s.classify(numberTask(source)));
      expect(result.result.value, 9);
      expect(executor.calls, hasLength(2));
    },
  );

  test('status does not collect missing or stale evidence', () async {
    await expectLater(
      service().run((s) => s.classify(numberTask(source)), restoreOnly: true),
      throwsStateError,
    );
    expect(source.snapshots, 0);
    expect(store.manifest, isNull);
    await service().run((s) => s.classify(numberTask(source)));
    source.subjects['entity'] = [7];
    await expectLater(
      service().run((s) => s.classify(numberTask(source)), restoreOnly: true),
      throwsStateError,
    );
    expect(source.snapshots, 1);
    expect(executor.calls, hasLength(1));
  });

  test(
    'model, classifier, and output contract changes invalidate caches',
    () async {
      await service().run((s) => s.classify(numberTask(source)));
      executor.configuration = 'executor-v2';
      await service().run((s) => s.classify(numberTask(source)));
      await service().run((s) => s.classify(numberTask(source, revision: 2)));
      final output = DataContract<int>(
        id: numberContract.id,
        revision: 2,
        schema: numberContract.schema,
        encode: numberContract.encode,
        decode: numberContract.decode,
      );
      final changed = ClassificationTask(
        key: 'entity',
        request: SourceRequest('entity'),
        source: source,
        plan: SingleRequestPlan(
          ClassifierDefinition(
            id: 'count',
            agentType: 'counter',
            instructions: 'Count observations.',
            input: numberContract,
            output: output,
          ),
        ),
      );
      await service().run((s) => s.classify(changed));
      expect(executor.calls, hasLength(4));
    },
  );

  test('refresh bypasses final and request checkpoints', () async {
    await service().run((s) => s.classify(numberTask(source)));
    await service().run((s) => s.classify(numberTask(source)), refresh: true);
    expect(executor.calls, hasLength(2));
  });

  test(
    'corrupt final record is rebuilt from a valid request checkpoint',
    () async {
      final record = await service().run((s) => s.classify(numberTask(source)));
      store.records[record.id]!['result'] = 'broken';
      await service().run((s) async {
        expect((await s.classify(numberTask(source))).result.value, 3);
        expect(s.reusedRequests, 1);
      });
      expect(executor.calls, hasLength(1));
    },
  );

  test(
    'cancellation interrupts hanging agent and saves earlier tasks',
    () async {
      final stop = JudgmentCancellation();
      executor.respond = (id, input) async {
        if (id == 'hang') {
          stop.cancel();
          return Completer<Map<String, Object?>>().future;
        }
        return numberResponse(id, input);
      };
      await expectLater(
        service().run((s) async {
          await s.classify(numberTask(source));
          await s.classify(numberTask(source, key: 'other', id: 'hang'));
        }, cancellation: stop),
        throwsStateError,
      );
      executor.respond = null;
      await service().run((s) async {
        await s.classify(numberTask(source));
        expect(s.restored, 1);
      });
    },
  );

  test('changes during execution reject final publication', () async {
    executor.respond = (id, input) async {
      source.subjects['entity'] = [99];
      return numberResponse(id, input);
    };
    await expectLater(
      service().run((s) => s.classify(numberTask(source))),
      throwsStateError,
    );
    expect(
      (store.manifest!['records'] as Map).keys.where(
        (k) => (k as String).startsWith('task:'),
      ),
      isEmpty,
    );
  });

  test('incomplete coverage cannot become a complete negative', () async {
    source.coverage = InputCoverage(complete: false, gaps: ['sampled only']);
    executor.respond = (_, _) async => {
      'outcome': 'notApplicable',
      'value': null,
      'evidence': [],
      'explanation': 'nothing found',
    };
    await expectLater(
      service().run((s) => s.classify(numberTask(source))),
      throwsFormatException,
    );
    executor.respond = (_, _) async => {
      'outcome': 'unknown',
      'value': null,
      'evidence': [],
      'explanation': 'insufficient input',
    };
    final result = await service().run(
      (s) => s.classify(numberTask(source)),
      refresh: true,
    );
    expect(result.coverage.complete, isFalse);
    expect(result.result.outcome, ClassificationOutcome.unknown);
  });

  test('unobserved citations are never checkpointed', () async {
    executor.respond = (_, _) async => {
      'outcome': 'classified',
      'value': 1,
      'evidence': ['invented'],
      'explanation': 'bad',
    };
    await expectLater(
      service().run((s) => s.classify(numberTask(source))),
      throwsFormatException,
    );
    expect(store.records, isEmpty);
  });

  test(
    'source and classifier contracts must agree even for the same Dart type',
    () {
      final other = MemorySource(
        DataContract<int>(
          id: 'another.semantic.type',
          schema: {'type': 'integer'},
          encode: (v) => v,
          decode: (v) => v as int,
        ),
        source.subjects,
      );
      expect(() => numberTask(other), throwsArgumentError);
    },
  );

  List<ClassificationNode<int, int>> graph() => [
    ClassificationNode('a', build: (_) => numberTask(source, key: 'a')),
    ClassificationNode(
      'b',
      requires: ['a'],
      build: (_) => numberTask(source, key: 'b'),
    ),
    ClassificationNode('c', build: (_) => numberTask(source, key: 'c')),
  ];
  test(
    'graph injects prerequisite identities and preserves unrelated branches',
    () async {
      source.subjects.addAll({
        'a': [1],
        'b': [2],
        'c': [3],
      });
      await service().run((s) => s.runGraph(graph()));
      source.subjects['a'] = [7];
      await service().run((s) async {
        final report = await s.runGraph(graph());
        expect(report.failures, isEmpty);
        expect(s.executed, 2);
        expect(s.restored, 1);
      });
    },
  );

  test('graph validates cycles before any source work', () async {
    await expectLater(
      service().run(
        (s) => s.runGraph<int, int>([
          ClassificationNode(
            'a',
            requires: ['b'],
            build: (_) => numberTask(source, key: 'a'),
          ),
          ClassificationNode(
            'b',
            requires: ['a'],
            build: (_) => numberTask(source, key: 'b'),
          ),
        ]),
      ),
      throwsArgumentError,
    );
    expect(source.snapshots, 0);
  });

  test(
    'failed prerequisite blocks descendants while siblings complete',
    () async {
      source.subjects.addAll({
        'a': [1],
        'b': [2],
        'c': [3],
      });
      executor.respond = (id, input) async {
        if (((input['evidence'] as List).first as Map)['value'] == 1)
          throw StateError('failed');
        return numberResponse(id, input);
      };
      final report = await service().run((s) => s.runGraph(graph()));
      expect(report.failures.keys, containsAll(['a', 'b']));
      expect(report.records.keys, ['c']);
    },
  );

  test('independent graph jobs overlap within the configured bound', () async {
    executor.respond = (id, input) async {
      await Future<void>.delayed(const Duration(milliseconds: 10));
      return numberResponse(id, input);
    };
    await service(concurrency: 2).run(
      (s) => s.runGraph<int, int>([
        for (var i = 0; i < 5; i++)
          ClassificationNode(
            'key$i',
            build: (_) => numberTask(source, key: 'key$i', id: 'job$i'),
          ),
      ]),
    );
    expect(executor.peak, 2);
  });
  test(
    'direct concurrent tasks share the global executor concurrency limit',
    () async {
      executor.respond = (id, input) async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
        return numberResponse(id, input);
      };
      await service(concurrency: 2).run(
        (s) => Future.wait([
          for (var i = 0; i < 8; i++)
            s.classify(numberTask(source, key: 'key$i', id: 'call$i')),
        ]),
      );
      expect(executor.peak, 2);
    },
  );

  test(
    'deadline cancels a stalled executor and admits no further work',
    () async {
      executor.respond = (_, _) => Completer<Map<String, Object?>>().future;
      await expectLater(
        service(timeout: const Duration(milliseconds: 20))
            .run((s) => s.classify(numberTask(source)))
            .timeout(const Duration(seconds: 1)),
        throwsStateError,
      );
      expect(store.records, isEmpty);
    },
  );

  test(
    'mutating JSON parameters cannot change a constructed request identity',
    () {
      final raw = <String, Object?>{
        'selection': <String>['one'],
      };
      final request = SourceRequest('customer:42', parameters: raw);
      (raw['selection'] as List).add('two');
      expect(request.parameters['selection'], ['one']);
    },
  );
}
