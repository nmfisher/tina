import 'package:test/test.dart';

import 'package:tina_index/edge.dart';
import 'package:tina_index/graph.dart';
import 'package:tina_index/graph_builder.dart';
import 'package:tina_index/symbol_table.dart';

import 'helpers/index_project.dart';

void main() {
  group('GraphBuilder', () {
    late CodeGraph graph;

    setUp(() async {
      final repoRoot = createIndexProject().path;
      final table = await SymbolTable.buildFromRepo(repoRoot);
      graph = GraphBuilder.build(table, repoRoot);
      GraphBuilder.addImportEdges(graph, repoRoot);
    });

    test('First extends Base', () {
      final firstEdges = graph.edgesFrom(
        'lib/first.First',
      );
      expect(
        firstEdges,
        contains(predicate<Edge>(
          (e) => e.kind == EdgeKind.extends_ && e.toId.contains('Base'),
        )),
      );
    });

    test('Second extends Base', () {
      final secondEdges = graph.edgesFrom(
        'lib/second.Second',
      );
      expect(
        secondEdges,
        contains(predicate<Edge>(
          (e) => e.kind == EdgeKind.extends_ && e.toId.contains('Base'),
        )),
      );
    });

    test('Base has multiple extends edges pointing to it', () {
      final toBase = graph.edgesTo('lib/base.Base');
      final extendsEdges =
          toBase.where((e) => e.kind == EdgeKind.extends_).toList();
      expect(extendsEdges.map((e) => e.fromId),
          unorderedEquals(['lib/first.First', 'lib/second.Second']));
    });

    test('class without a superclass has no extends edge', () {
      final controllerId = graph.symbols.qualifiedNames.firstWhere(
        (q) => q == 'lib/controller.Controller',
      );
      final controllerEdges = graph.edgesFrom(controllerId);
      expect(
        controllerEdges.where((e) => e.kind == EdgeKind.extends_),
        isEmpty,
      );
    });

    test('summaries can be set and retrieved via manifest', () {
      const controllerPath = 'lib/controller.dart';
      graph.setSummary(controllerPath, 'abc123', 'Controller entry point');
      expect(graph.summaryFor(controllerPath), 'Controller entry point');
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

    test('relative imports resolve to indexed files', () {
      final importEdges = graph
          .edgesFrom('lib/controller.dart')
          .where((e) => e.kind == EdgeKind.imports);
      expect(
        importEdges.map((e) => e.toId),
        contains('lib/first.dart'),
      );
    });

    test('package imports resolve within the project', () {
      final importEdges = graph
          .edgesFrom('lib/second.dart')
          .where((e) => e.kind == EdgeKind.imports);
      expect(
        importEdges.map((e) => e.toId),
        contains('lib/base.dart'),
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
