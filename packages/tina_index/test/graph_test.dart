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
      final anthropicEdges = graph.edgesFrom(
        'packages/tina_engine/lib/src/llm/anthropic.AnthropicProvider',
      );
      expect(
        anthropicEdges,
        contains(predicate<Edge>(
          (e) =>
              e.kind == EdgeKind.extends_ &&
              e.toId.contains('LlmProvider'),
        )),
      );
    });

    test('OpenAiCompatibleAdapter extends LlmProvider', () {
      final openaiEdges = graph.edgesFrom(
        'packages/tina_engine/lib/src/llm/openai_compatible.OpenAiCompatibleAdapter',
      );
      expect(
        openaiEdges,
        contains(predicate<Edge>(
          (e) =>
              e.kind == EdgeKind.extends_ &&
              e.toId.contains('LlmProvider'),
        )),
      );
    });

    test('LlmProvider has multiple extends edges pointing to it', () {
      final toLlmProvider =
          graph.edgesTo('packages/tina_engine/lib/src/llm/provider.LlmProvider');
      final extendsEdges =
          toLlmProvider.where((e) => e.kind == EdgeKind.extends_).toList();
      // anthropic, gemini, and openai_compatible all extend it; keep the
      // bound loose so adding a provider doesn't break this test.
      expect(extendsEdges.length, greaterThanOrEqualTo(2));
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
      const agentPath = 'packages/tina_engine/lib/src/agent/agent.dart';
      graph.setSummary(agentPath, 'abc123', 'Core agent loop');
      expect(graph.summaryFor(agentPath), 'Core agent loop');
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

    test('agent.dart imports agent_sink.dart', () {
      final importEdges = graph
          .edgesFrom('packages/tina_engine/lib/src/agent/agent.dart')
          .where((e) => e.kind == EdgeKind.imports);
      expect(
        importEdges.map((e) => e.toId),
        contains('packages/tina_engine/lib/src/agent/agent_sink.dart'),
      );
    });

    test('anthropic.dart imports provider.dart', () {
      final importEdges = graph
          .edgesFrom('packages/tina_engine/lib/src/llm/anthropic.dart')
          .where((e) => e.kind == EdgeKind.imports);
      expect(
        importEdges.map((e) => e.toId),
        contains('packages/tina_engine/lib/src/llm/provider.dart'),
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
