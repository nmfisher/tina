import 'package:tina_index/tina_index.dart';

void main() {
  final graph = GraphStore.rebuildFromRepo('.');

  print('Symbols: ${graph.symbols.length}');
  print('Edges:   ${graph.edges.length}');
  print('');

  final result = GraphTraversal.expand(
    graph,
    ['lib/llm/provider.LlmProvider'],
    hops: 2,
  );

  print('2-hop expansion from LlmProvider:');
  for (final id in result.nodes.keys) {
    final sym = result.nodes[id]!;
    final edges = result.edges
        .where((e) => e.fromId == id || e.toId == id)
        .map((e) {
      if (e.fromId == id) return '→ ${e.kind.name}: ${e.toId}';
      return '← ${e.kind.name}: ${e.fromId}';
    }).join(', ');
    print('  $id (${sym.kind.name}${sym.isAbstract ? ', abstract' : ''})'
        '${edges.isNotEmpty ? '\n    $edges' : ''}');
  }
}
