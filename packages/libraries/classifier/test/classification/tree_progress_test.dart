import 'dart:async';

import 'package:classifier/classification.dart';
import 'package:classifier/judgments.dart';
import 'package:test/test.dart';
import 'helpers.dart';

class TreeMemory extends MemorySource<int> implements TreeSource<int> {
  TreeMemory(Map<String, List<int>> values, {super.identity})
    : super(numberContract, values);
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
  ) async => view();

  @override
  Future<bool> isTreeCurrent(
    SourceRevision revision,
    JudgmentCancellation cancellation,
  ) async => true;
}

TreePlan<int, int> plan({int revision = 1, String id = 'count'}) => TreePlan(
  id: id,
  output: numberContract,
  local: (node) =>
      SingleRequestPlan(numberDefinition('local:${node.key}', revision)),
  merge: (node) => SingleRequestPlan(
    ClassifierDefinition(
      id: 'merge:${node.key}',
      agentType: 'counter',
      instructions: 'Sum child and local counts.',
      input: partContract(numberContract),
      output: numberContract,
    ),
  ),
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
  ClassificationOrchestrator service() => ClassificationOrchestrator(
    store: store,
    executor: executor,
    concurrency: 2,
    timeout: const Duration(seconds: 10),
  );
  setUp(() {
    store = MemoryStore();
    executor = Executor()..respond = (id, input) async => sum(id, input);
    source = TreeMemory({
      'user': [1],
      'dev': [2],
    });
  });

  test(
    'tree run announces its total up front and counts settled tasks',
    () async {
      final done = <int>[];
      var total = 0;
      final report = await service().run(
        (s) => s.runTree(
          source: source,
          request: SourceRequest('.'),
          plan: plan(),
        ),
        onTaskProgress: (d, t) {
          total = t;
          done.add(d);
        },
      );
      expect(report.records['.']!.result.value, 3);
      expect(total, 5, reason: '2 leaf locals + 2 leaf merges + root merge');
      expect(
        done.first,
        0,
        reason: 'total is announced before any task settles',
      );
      expect(done, everyElement(lessThanOrEqualTo(total)));
      expect(done.last, 5);
      expect(
        done.toSet().length,
        done.length,
        reason: 'monotonically increasing',
      );
      expect(executor.calls, hasLength(5));
    },
  );

  test('tree totals are per run, not cumulative across runs', () async {
    await service().run(
      (s) =>
          s.runTree(source: source, request: SourceRequest('.'), plan: plan()),
    );
    var total = -1;
    await service().run(
      (s) =>
          s.runTree(source: source, request: SourceRequest('.'), plan: plan()),
      onTaskProgress: (d, t) => total = t,
    );
    expect(total, 5, reason: 'second run must not inherit the first run total');
  });

  test('multi-tree run adds each tree to the announced total', () async {
    var total = 0;
    await service().run((s) async {
      await s.runTree(
        source: source,
        request: SourceRequest('.'),
        plan: plan(),
      );
      await s.runTree(
        source: source,
        request: SourceRequest('.'),
        plan: plan(id: 'other'),
      );
    }, onTaskProgress: (d, t) => total = t);
    expect(total, 10, reason: 'both trees announce; total never resets');
    // Tree 2's locals are content-identical to tree 1's, so they restore from
    // checkpoints; only its merges execute. Restored tasks still settle, and
    // both still count against the announced total.
    expect(executor.calls, hasLength(8));
  });
}
