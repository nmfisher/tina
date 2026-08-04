import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:test/test.dart';

import 'package:tina_index/edge.dart';
import 'package:tina_index/graph.dart';
import 'package:tina_index/graph_builder.dart';
import 'package:tina_index/symbol_table.dart';

String get repoRoot => p.normalize(p.join(Directory.current.path, '..', '..'));

void main() {
  group('GraphBuilder', () {
    late CodeGraph graph;

    setUpAll(() async {
      final table = await SymbolTable.buildFromRepo(repoRoot);
      graph = GraphBuilder.build(table, repoRoot);
      GraphBuilder.addImportEdges(graph, repoRoot);
    });

    test('AnthropicProvider extends LlmProvider', () {
      final anthropicEdges =
          graph.edgesFrom('lib/llm/anthropic.AnthropicProvider');
      expect(
        anthropicEdges,
        contains(predicate<Edge>(
          (e) =>
              e.kind == EdgeKind.extends_ &&
              e.toId.contains('LlmProvider'),
        )),
      );
    });

    test('OpenAiProvider extends LlmProvider', () {
      final openaiEdges =
          graph.edgesFrom('lib/llm/openai.OpenAiProvider');
      expect(
        openaiEdges,
        contains(predicate<Edge>(
          (e) =>
              e.kind == EdgeKind.extends_ &&
              e.toId.contains('LlmProvider'),
        )),
      );
    });

    test('LlmProvider has two extends edges pointing to it', () {
      final toLlmProvider =
          graph.edgesTo('lib/llm/provider.LlmProvider');
      final extendsEdges =
          toLlmProvider.where((e) => e.kind == EdgeKind.extends_).toList();
      expect(extendsEdges, hasLength(2));
    });

    test('Agent has no extends edge', () {
      final agentQName = graph.symbols.qualifiedNames.firstWhere(
        (q) => q.endsWith('.Agent') && q.contains('agent/agent'),
      );
      final agentEdges = graph.edgesFrom(agentQName);
      expect(
        agentEdges.where((e) => e.kind == EdgeKind.extends_),
        isEmpty,
      );
    });

    test('graph has edges', () {
      expect(graph.edges, isNotEmpty);
    });

    test('summaries can be set and retrieved via manifest', () {
      graph.setSummary('lib/agent/agent.dart', 'abc123', 'Core agent loop');
      expect(graph.summaryFor('lib/agent/agent.dart'), 'Core agent loop');
      expect(graph.summaryFor('nonexistent.dart'), isNull);
    });

    test('hasSummary checks by hash', () {
      graph.setSummary('test.key', 'hash789', 'test summary');
      expect(graph.hasSummary('hash789'), isTrue);
      expect(graph.hasSummary('missing'), isFalse);
    });

    test('setContentHash registers manifest without summary', () {
      graph.setContentHash('test.noSummary', 'hash000');
      expect(graph.manifest['test.noSummary'], 'hash000');
      expect(graph.summaryFor('test.noSummary'), isNull);
    });

    test('all edge targets are valid symbol IDs', () {
      for (final e in graph.edges) {
        // Structural edges point to symbol qualified names.
        if (e.kind != EdgeKind.imports && e.kind != EdgeKind.exports) {
          expect(
            graph.symbols[e.toId],
            isNotNull,
            reason: 'Edge target ${e.toId} not found in symbol table',
          );
        }
      }
    });

    test('agent.dart imports stream_consumer.dart', () {
      final importEdges =
          graph.edgesFrom('lib/agent/agent.dart').where((e) => e.kind == EdgeKind.imports);
      expect(
        importEdges.map((e) => e.toId),
        contains('lib/agent/stream_consumer.dart'),
      );
    });

    test('anthropic.dart imports provider.dart', () {
      final importEdges =
          graph.edgesFrom('lib/llm/anthropic.dart').where((e) => e.kind == EdgeKind.imports);
      expect(
        importEdges.map((e) => e.toId),
        contains('lib/llm/provider.dart'),
      );
    });

    test('no import edges to external packages', () {
      for (final e in graph.edges) {
        if (e.kind == EdgeKind.imports || e.kind == EdgeKind.exports) {
          expect(e.toId, isNot(contains('package:')));
          expect(e.toId, isNot(contains('dart:')));
        }
      }
    });
  });
}
