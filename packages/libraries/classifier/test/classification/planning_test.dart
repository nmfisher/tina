import 'package:classifier/classification.dart';
import 'package:test/test.dart';

import 'helpers.dart';

ClassificationPlan<int, String> sumPlan() {
  final partial = partialObservationContract(numberContract);
  return ChunkedClassificationPlan<int, int, String>(
    direct: ClassifierDefinition(
      id: 'direct',
      agentType: 'describe',
      instructions: 'Describe sum.',
      input: numberContract,
      output: stringContract,
    ),
    observe: numberDefinition('observe'),
    combine: ClassifierDefinition(
      id: 'combine',
      agentType: 'sum',
      instructions: 'Add partial counts.',
      input: partial,
      output: numberContract,
    ),
    finalize: ClassifierDefinition(
      id: 'final',
      agentType: 'describe',
      instructions: 'Describe sum.',
      input: partial,
      output: stringContract,
    ),
  );
}

void main() {
  late MemoryStore store;
  late Executor executor;
  late MemorySource<int> source;
  setUp(() {
    store = MemoryStore();
    source = MemorySource(numberContract, {'entity': List.filled(16, 1)});
    executor = Executor()
      ..count = (request) =>
          5 + (jsonObject(request['input'])['evidence'] as List).length * 10;
  });
  ClassificationTask<int, String> task() => ClassificationTask(
    key: 'entity',
    request: SourceRequest('entity'),
    source: source,
    plan: sumPlan(),
  );
  ClassificationOrchestrator service({int maxCalls = 128, int input = 35}) =>
      ClassificationOrchestrator(
        store: store,
        executor: executor,
        budget: smallBudget(input),
        maxCalls: maxCalls,
      );

  test(
    'maps to a distinct partial type and performs bounded hierarchical reduction',
    () async {
      final result = await service().run((s) => s.classify(task()));
      expect(result.result.value, 'total=16');
      expect(executor.calls.where((id) => id == 'observe'), hasLength(6));
      expect(executor.calls.where((id) => id == 'combine'), hasLength(2));
      expect(executor.calls.last, 'final');
    },
  );

  test('uses one direct request when the complete input fits', () async {
    source.subjects['entity'] = [1, 2];
    expect(
      (await service().run((s) => s.classify(task()))).result.value,
      'total=3',
    );
    expect(executor.calls, ['direct']);
  });

  test(
    'interrupted map work resumes from completed request checkpoints',
    () async {
      await expectLater(
        service(maxCalls: 2).run((s) => s.classify(task())),
        throwsStateError,
      );
      expect(executor.calls, hasLength(2));
      await service().run((s) async {
        expect((await s.classify(task())).result.value, 'total=16');
        expect(s.reusedRequests, 2);
      });
      expect(executor.calls.where((id) => id == 'observe'), hasLength(6));
    },
  );

  test(
    'reducer which cannot fit a pair fails without dropping observations',
    () async {
      await expectLater(
        service(input: 15).run((s) => s.classify(task())),
        throwsA(isA<InputTooLargeException>()),
      );
      expect(executor.calls.where((id) => id == 'observe'), hasLength(16));
      expect(executor.calls, isNot(contains('final')));
    },
  );

  test(
    'fixed request overhead and upstream data are included in the context budget',
    () async {
      executor.count = null;
      final request = ClassificationRequest(
        numberDefinition(),
        ClassificationInput<int>(
          [],
          InputCoverage(),
          upstream: {'large': 'x' * 1000},
        ),
      );
      final estimate = executor.estimate(request);
      final withUpstream = ClassificationTask(
        key: 'entity',
        request: SourceRequest('entity'),
        source: source,
        plan: SingleRequestPlan(numberDefinition()),
        upstream: {'large': 'x' * 1000},
      );
      await expectLater(
        ClassificationOrchestrator(
          store: store,
          executor: executor,
          budget: smallBudget(estimate - 1),
        ).run((s) => s.classify(withUpstream)),
        throwsA(isA<InputTooLargeException>()),
      );
      expect(executor.calls, isEmpty);
    },
  );

  test('output reserve and safety margin reduce available input', () {
    final budget = ClassificationBudget(
      contextTokens: 100,
      outputTokens: 30,
      safetyTokens: 10,
      maxInputTokens: 90,
    );
    expect(budget.inputLimit, 60);
  });

  test(
    'chunk cap rejects work before dispatch instead of silently clipping it',
    () async {
      final limited = ClassificationOrchestrator(
        store: store,
        executor: executor,
        budget: ClassificationBudget(
          contextTokens: 100,
          outputTokens: 20,
          safetyTokens: 10,
          maxInputTokens: 35,
          maxChunks: 2,
        ),
      );
      await expectLater(
        limited.run((s) => s.classify(task())),
        throwsA(isA<InputTooLargeException>()),
      );
      expect(executor.calls, isEmpty);
    },
  );

  test(
    'text splitter preserves Unicode and complete coverage with stable scalar spans',
    () {
      const text = 'abc😀def\nghi🌍jklmnop';
      final unit = SourceUnit(
        'document:42',
        TextEvidence('document', text),
        location: {'record': 42},
      );
      final chunks = packClassificationUnits(
        [unit],
        splitter: const TextInputSplitter(),
        maxChunks: 20,
        fits: (units) =>
            units.fold<int>(0, (n, u) => n + u.value.text.runes.length) <= 6,
      );
      final parts = chunks.expand((c) => c).toList();
      expect(parts.map((u) => u.value.text).join(), text);
      expect(parts.first.location['start_scalar'], 0);
      expect(parts.last.location['end_scalar'], text.runes.length);
      for (var i = 1; i < parts.length; i++) {
        expect(
          parts[i].location['start_scalar'],
          parts[i - 1].location['end_scalar'],
        );
      }
      expect(parts.every((p) => p.value.meaning.contains('excerpt')), isTrue);
    },
  );

  test('atomic input cannot be split without a source splitting policy', () {
    expect(
      () => packClassificationUnits(
        [SourceUnit('record', 'very large')],
        fits: (u) => u.isEmpty,
        maxChunks: 3,
      ),
      throwsA(isA<InputTooLargeException>()),
    );
  });

  test(
    'aggregation rejects incompatible partial contracts at construction',
    () {
      final partial = partialObservationContract(numberContract);
      final wrong = DataContract<PartialObservation<int>>(
        id: 'wrong',
        schema: partial.schema,
        encode: partial.encode,
        decode: partial.decode,
      );
      expect(
        () => ChunkedClassificationPlan<int, int, String>(
          direct: ClassifierDefinition(
            id: 'direct',
            agentType: 'a',
            instructions: 'a',
            input: numberContract,
            output: stringContract,
          ),
          observe: numberDefinition(),
          combine: ClassifierDefinition(
            id: 'combine',
            agentType: 'a',
            instructions: 'a',
            input: wrong,
            output: numberContract,
          ),
          finalize: ClassifierDefinition(
            id: 'final',
            agentType: 'a',
            instructions: 'a',
            input: partial,
            output: stringContract,
          ),
        ),
        throwsArgumentError,
      );
    },
  );
  test(
    'final records retain the map/reduce checkpoint chain without raw inputs',
    () async {
      final record = await service().run((s) => s.classify(task()));
      final saved = store.records[record.id]!;
      final requests = (saved['request_records'] as List).cast<String>();
      expect(requests, hasLength(executor.calls.length));
      expect(requests.every(store.records.containsKey), isTrue);
      final provenance = store.records[requests.first]!['provenance'] as Map;
      expect(provenance['evidence_units'], isNotEmpty);
      expect(provenance['request'], isA<String>());
    },
  );

  test('source splitter revisions invalidate final records', () async {
    final textSource = MemorySource(textEvidenceContract, {
      'item': [TextEvidence('message', 'hello')],
    }, splitter: const TextInputSplitter());
    final classifier = ClassifierDefinition(
      id: 'text',
      agentType: 'text',
      instructions: 'Classify text.',
      input: textEvidenceContract,
      output: stringContract,
    );
    executor.respond = (_, _) async => {
      'outcome': 'classified',
      'value': 'greeting',
      'evidence': ['entry:0'],
      'explanation': 'message',
    };
    ClassificationTask<TextEvidence, String> textTask() => ClassificationTask(
      key: 'item',
      request: SourceRequest('item'),
      source: textSource,
      plan: SingleRequestPlan(classifier),
    );
    await service().run((s) => s.classify(textTask()));
    textSource.splitter = RevisedSplitter();
    await service().run((s) => s.classify(textTask()));
    expect(executor.calls, hasLength(2));
  });
}

class RevisedSplitter extends TextInputSplitter {
  @override
  Object get identity => {'id': 'classifier.text_splitter', 'revision': 2};
}
