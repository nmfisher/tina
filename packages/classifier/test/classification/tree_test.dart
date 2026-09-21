import 'dart:async';

import 'package:classifier/classification.dart';
import 'package:classifier/judgments.dart';
import 'package:test/test.dart';
import 'helpers.dart';

class TreeMemory extends MemorySource<int> implements TreeSource<int> {
  TreeMemory(Map<String, List<int>> values, {super.identity})
    : super(numberContract, values);
  bool hang = false;
  TreeSnapshot view() {
    final children = <String, Set<String>>{'.': {}};
    for (var key in subjects.keys) {
      children.putIfAbsent(key, () => {});
      while (key != '.') {
        final slash = key.lastIndexOf('/');
        final parent = slash < 0 ? '.' : key.substring(0, slash);
        (children[parent] ??= {}).add(key);
        key = parent;
      }
    }
    return TreeSnapshot(
      '.',
      [
        for (final key in children.keys)
          Node(
            key,
            input: subjects.containsKey(key) ? SourceRequest(key) : null,
            children: children[key]!,
          ),
      ],
      SourceRevision({
        'shape': canonicalFingerprint({
          for (final entry in children.entries)
            entry.key: {
              'children': entry.value.toList()..sort(),
              'input': subjects.containsKey(entry.key),
            },
        }),
      }),
    );
  }

  @override
  Future<TreeSnapshot> tree(
    SourceRequest request,
    JudgmentCancellation cancellation,
  ) async => hang ? Completer<TreeSnapshot>().future : view();
  @override
  Future<bool> isTreeCurrent(
    SourceRevision revision,
    JudgmentCancellation cancellation,
  ) async =>
      canonicalFingerprint(revision.receipt) ==
      canonicalFingerprint(view().revision.receipt);
}

TreePlan<int, int> plan({int revision = 1, bool chunked = false}) => TreePlan(
  id: 'count',
  output: numberContract,
  local: (node) =>
      SingleRequestPlan(numberDefinition('local:${node.key}', revision)),
  merge: (node) {
    final direct = ClassifierDefinition(
      id: 'merge:${node.key}',
      agentType: 'counter',
      instructions: 'Sum child and local counts.',
      input: partContract(numberContract),
      output: numberContract,
    );
    if (!chunked) return SingleRequestPlan(direct);
    ClassifierDefinition<PartialObservation<int>, int> reduce(String stage) =>
        ClassifierDefinition(
          id: stage,
          agentType: 'counter',
          instructions: 'Sum partial counts.',
          input: partialObservationContract(numberContract),
          output: numberContract,
        );
    return ChunkedClassificationPlan(
      direct: direct,
      observe: direct,
      combine: reduce('combine'),
      finalize: reduce('finish'),
    );
  },
);

Map<String, Object?> sum(String id, Map<String, Object?> input) {
  var total = 0;
  final units = (input['evidence'] as List).cast<Map>();
  for (final unit in units) {
    final value = unit['value'];
    total += value is int
        ? value
        : ((value as Map)['result'] as Map? ?? value)['value'] as int? ?? 0;
  }
  return {
    'outcome': 'classified',
    'value': total,
    'evidence': units.map((u) => u['id']).toList(),
    'explanation': 'Sum of supplied values.',
  };
}

void main() {
  late MemoryStore store;
  late Executor executor;
  late TreeMemory source;
  ClassificationOrchestrator service({
    ClassificationBudget? budget,
    Duration? timeout,
  }) => ClassificationOrchestrator(
    store: store,
    executor: executor,
    concurrency: 2,
    budget: budget,
    timeout: timeout ?? const Duration(seconds: 10),
  );
  Future<TreeReport<int>> run({bool restore = false, int revision = 1}) =>
      service().run(
        (s) => s.runTree(
          source: source,
          request: SourceRequest('.'),
          plan: plan(revision: revision),
        ),
        restoreOnly: restore,
      );
  setUp(() {
    store = MemoryStore();
    executor = Executor()..respond = (id, input) async => sum(id, input);
    source = TreeMemory({
      'docs/user': [1],
      'docs/dev': [2],
      'src': [3],
      'test': [4],
    });
  });

  test(
    'changed leaf reruns only its local and affected ancestor merges',
    () async {
      expect((await run()).records['.']!.result.value, 10);
      executor.calls.clear();
      source.subjects['docs/user'] = [7];
      final next = await run();
      expect(next.failures, isEmpty);
      expect(next.records['.']!.result.value, 16);
      expect(executor.calls, [
        'local:docs/user',
        'merge:docs/user',
        'merge:docs',
        'merge:.',
      ]);
    },
  );

  test(
    'same consumed result stops propagation despite a new local record',
    () async {
      source.subjects['docs/user'] = [1, 2];
      final before = await run();
      executor.calls.clear();
      source.subjects['docs/user'] = [2, 1];
      final after = await run();
      expect(
        after.local['docs/user']!.id,
        isNot(before.local['docs/user']!.id),
      );
      expect(after.records['.']!.id, before.records['.']!.id);
      expect(executor.calls, ['local:docs/user']);
    },
  );

  test(
    'a new source and session restore all results without input preparation',
    () async {
      await run();
      executor.calls.clear();
      source = TreeMemory(Map.of(source.subjects));
      final restored = await run(restore: true);
      expect(restored.failures, isEmpty);
      expect(restored.records['.']!.result.value, 10);
      expect(source.snapshots, 0);
      expect(executor.calls, isEmpty);
    },
  );

  test(
    'additions, removals and moves rebuild membership without stale children',
    () async {
      await run();
      source.subjects['docs/admin'] = [8];
      expect((await run()).records['docs']!.result.value, 11);
      source.subjects.remove('docs/dev');
      expect((await run()).records['docs']!.result.value, 9);
      source.subjects['src/admin'] = source.subjects.remove('docs/admin')!;
      final moved = await run();
      expect(moved.records['docs']!.result.value, 1);
      expect(moved.records['src']!.result.value, 11);
      expect(moved.records['.']!.result.value, 16);
      expect(moved.records, isNot(contains('docs/admin')));
    },
  );

  test('source and classifier configuration invalidate locals', () async {
    await run();
    executor.calls.clear();
    await run(revision: 2);
    expect(executor.calls.where((id) => id.startsWith('local:')), hasLength(4));
    executor.calls.clear();
    source = TreeMemory(source.subjects, identity: 'different encoder');
    await run(revision: 2);
    expect(executor.calls.where((id) => id.startsWith('local:')), hasLength(4));
  });

  test('failed child blocks ancestors but unrelated siblings finish', () async {
    executor.respond = (id, input) async {
      if (id == 'local:docs/user') throw StateError('unavailable');
      return sum(id, input);
    };
    final report = await run();
    expect(report.failures.keys, containsAll(['docs/user', 'docs', '.']));
    expect(report.records.keys, containsAll(['docs/dev', 'src', 'test']));
    executor.calls.clear();
    executor.respond = (id, input) async => sum(id, input);
    expect((await run()).failures, isEmpty);
    expect(executor.calls, [
      'local:docs/user',
      'merge:docs/user',
      'merge:docs',
      'merge:.',
    ]);
  });

  test('incomplete child coverage survives every merge', () async {
    source.coverage = InputCoverage(complete: false, gaps: ['omitted input']);
    final report = await run();
    expect(report.records['.']!.coverage.complete, isFalse);
    expect(report.records['.']!.coverage.gaps, isNotEmpty);
  });

  test(
    'a change to an already completed child invalidates the returned tree',
    () async {
      executor.respond = (id, input) async {
        if (id == 'merge:.') source.subjects['docs/user'] = [99];
        return sum(id, input);
      };
      final report = await run();
      expect(report.records, isEmpty);
      expect(report.failures['.'], contains('changed'));
    },
  );

  test(
    'cancellation interrupts a stalled agent and preserves completed locals',
    () async {
      final stop = JudgmentCancellation();
      executor.respond = (id, input) async {
        if (id == 'merge:docs') {
          stop.cancel();
          return Completer<Map<String, Object?>>().future;
        }
        return sum(id, input);
      };
      final report = await service().run(
        (s) => s.runTree(
          source: source,
          request: SourceRequest('.'),
          plan: plan(),
        ),
        cancellation: stop,
      );
      expect(report.failures, isNotEmpty);
      executor.respond = (id, input) async => sum(id, input);
      executor.calls.clear();
      expect((await run()).failures, isEmpty);
      expect(executor.calls, containsAll(['merge:docs', 'merge:.']));
      expect(executor.calls.any((id) => id.startsWith('local:')), isFalse);
    },
  );

  test('tree discovery obeys the session deadline', () async {
    source.hang = true;
    await expectLater(
      service(timeout: const Duration(milliseconds: 30)).run(
        (s) => s.runTree(
          source: source,
          request: SourceRequest('.'),
          plan: plan(),
        ),
      ),
      throwsStateError,
    );
  });

  test('wide merges use the existing chunk and reduction budgets', () async {
    source = TreeMemory({
      for (var i = 0; i < 9; i++) 'item$i': [i],
    });
    executor.count = (request) =>
        10 + ((request['input'] as Map)['evidence'] as List).length * 10;
    final report = await service(budget: smallBudget(40)).run(
      (s) => s.runTree(
        source: source,
        request: SourceRequest('.'),
        plan: plan(chunked: true),
      ),
    );
    expect(report.failures, isEmpty);
    expect(report.records['.']!.result.value, 36);
    expect(executor.calls, contains('finish'));
  });

  test('invalid topology fails before any classification', () {
    expect(
      () => TreeSnapshot('.', [
        Node('.', children: ['missing']),
      ], SourceRevision({})),
      throwsArgumentError,
    );
    expect(
      () => TreeSnapshot('.', [Node('.'), Node('orphan')], SourceRevision({})),
      throwsArgumentError,
    );
    expect(
      () => TreeSnapshot('.', [
        Node('.', children: ['a']),
        Node('a', children: ['.']),
      ], SourceRevision({})),
      throwsArgumentError,
    );
    expect(executor.calls, isEmpty);
  });
}
