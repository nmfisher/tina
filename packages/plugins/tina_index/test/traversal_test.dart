import 'package:test/test.dart';

import 'package:tina_index/graph.dart';
import 'package:tina_index/store.dart';
import 'package:tina_index/traversal.dart';

import 'helpers/index_project.dart';

void main() {
  group('GraphTraversal', () {
    late CodeGraph graph;
    late String repoRoot;

    setUp(() {
      repoRoot = createIndexProject().path;
      graph = GraphStore.rebuildFromRepo(repoRoot);
    });

    test('hops=0 returns seed nodes only', () {
      final result = GraphTraversal.expand(
        graph,
        ['lib/controller.Controller'],
        hops: 0,
        repoRoot: repoRoot,
      );
      expect(result.nodes, contains('lib/controller.Controller'));
      expect(result.nodes.length, 1);
    });

    test('hops=1 from Controller reaches other symbols', () {
      const controllerId = 'lib/controller.Controller';
      final result = GraphTraversal.expand(
        graph,
        [controllerId],
        hops: 1,
        repoRoot: repoRoot,
      );
      expect(result.nodes, contains(controllerId));
      expect(result.nodes.length, greaterThan(1));
    });

    test('hops=2 from Base reaches both subclasses', () {
      final result = GraphTraversal.expand(
        graph,
        ['lib/base.Base'],
        hops: 2,
        repoRoot: repoRoot,
      );
      expect(result.nodes, contains('lib/base.Base'));
      expect(
        result.nodes.keys.any((k) => k.contains('First')),
        isTrue,
        reason: 'Should reach First within 2 hops',
      );
      expect(
        result.nodes.keys.any((k) => k.contains('Second')),
        isTrue,
        reason: 'Should reach Second within 2 hops',
      );
    });

    test('maxNodes caps expansion', () {
      final result = GraphTraversal.expand(
        graph,
        ['lib/base.Base'],
        hops: 5,
        maxNodes: 3,
        repoRoot: repoRoot,
      );
      expect(result.nodes.length, lessThanOrEqualTo(3));
    });

    test('readSource returns source text for Controller', () {
      final controller = graph.symbols['lib/controller.Controller'];
      expect(controller, isNotNull);
      final source = GraphTraversal.readSource(controller!);
      expect(source, isNotNull);
      expect(source, contains('class Controller'));
    });

    test('empty seeds return empty subgraph', () {
      final result = GraphTraversal.expand(graph, [], hops: 2);
      expect(result.nodes, isEmpty);
    });

    test('nonexistent seed returns empty subgraph', () {
      final result = GraphTraversal.expand(
        graph,
        ['nonexistent.Symbol'],
        hops: 2,
      );
      expect(result.nodes, isEmpty);
    });

    test('interface-consumer expansion at hops=0', () {
      final result = GraphTraversal.expand(
        graph,
        ['lib/base.Base'],
        hops: 0,
        repoRoot: repoRoot,
      );
      expect(result.nodes, contains('lib/base.Base'));
      expect(
        result.nodes.keys.any((k) => k.contains('First')),
        isTrue,
        reason: 'Interface-consumer expansion should pull in First',
      );
      expect(
        result.nodes.keys.any((k) => k.contains('Second')),
        isTrue,
        reason: 'Interface-consumer expansion should pull in Second',
      );
    });
  });
}
