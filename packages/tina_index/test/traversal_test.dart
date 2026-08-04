import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:test/test.dart';

import 'package:tina_index/edge.dart';
import 'package:tina_index/graph.dart';
import 'package:tina_index/store.dart';
import 'package:tina_index/traversal.dart';

String get repoRoot => p.normalize(p.join(Directory.current.path, '..', '..'));

void main() {
  group('GraphTraversal', () {
    late CodeGraph graph;

    setUpAll(() {
      graph = GraphStore.rebuildFromRepo(repoRoot);
    });

    test('hops=0 returns seed nodes only', () {
      final result = GraphTraversal.expand(
        graph,
        ['lib/agent/agent.Agent'],
        hops: 0,
        repoRoot: repoRoot,
      );
      expect(result.nodes, contains('lib/agent/agent.Agent'));
      expect(result.nodes.length, 1);
    });

    test('hops=1 from Agent reaches other symbols', () {
      final agentQName = 'lib/agent/agent.Agent';
      final result = GraphTraversal.expand(
        graph,
        [agentQName],
        hops: 1,
        repoRoot: repoRoot,
      );
      expect(result.nodes, contains(agentQName));
      expect(result.nodes.length, greaterThan(1));
    });

    test('hops=2 from LlmProvider reaches both providers', () {
      final result = GraphTraversal.expand(
        graph,
        ['lib/llm/provider.LlmProvider'],
        hops: 2,
        repoRoot: repoRoot,
      );
      expect(result.nodes, contains('lib/llm/provider.LlmProvider'));
      expect(
        result.nodes.keys.any((k) => k.contains('AnthropicProvider')),
        isTrue,
        reason: 'Should reach AnthropicProvider within 2 hops',
      );
      expect(
        result.nodes.keys.any((k) => k.contains('OpenAiProvider')),
        isTrue,
        reason: 'Should reach OpenAiProvider within 2 hops',
      );
    });

    test('maxNodes caps expansion', () {
      final result = GraphTraversal.expand(
        graph,
        ['lib/llm/provider.LlmProvider'],
        hops: 5,
        maxNodes: 3,
        repoRoot: repoRoot,
      );
      expect(result.nodes.length, lessThanOrEqualTo(3));
    });

    test('readSource returns source text for Agent', () {
      final agent = graph.symbols['lib/agent/agent.Agent'];
      expect(agent, isNotNull);
      final source = GraphTraversal.readSource(agent!);
      expect(source, isNotNull);
      expect(source, contains('class Agent'));
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
        ['lib/llm/provider.LlmProvider'],
        hops: 0,
        repoRoot: repoRoot,
      );
      expect(result.nodes, contains('lib/llm/provider.LlmProvider'));
      expect(
        result.nodes.keys.any((k) => k.contains('AnthropicProvider')),
        isTrue,
        reason: 'Interface-consumer expansion should pull in AnthropicProvider',
      );
      expect(
        result.nodes.keys.any((k) => k.contains('OpenAiProvider')),
        isTrue,
        reason: 'Interface-consumer expansion should pull in OpenAiProvider',
      );
    });
  });
}
