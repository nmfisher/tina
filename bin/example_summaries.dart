import 'package:path/path.dart' as p;
import 'package:tina_index/tina_index.dart';

void main() {
  final repoRoot = '.';
  final graph = GraphStore.rebuildFromRepo(repoRoot);

  // Stamp hard-coded summaries for a few files, using content hashes.
  const dummySummaries = {
    'lib/agent/agent.dart':
      'Core agent loop: orchestrates LLM calls, tool execution, and conversation history.',
    'lib/llm/provider.dart':
      'Defines the LlmProvider interface with streaming send() and token usage tracking.',
    'lib/llm/anthropic.dart':
        'Anthropic API provider implementing streaming with retry and error handling.',
    'lib/llm/openai.dart':
        'OpenAI-compatible API provider with streaming support.',
    'lib/llm/message.dart':
        'Message and ContentBlock types for the conversation protocol.',
    'lib/tools/tool.dart':
        'Tool interface, schema, and registry for the agent\'s tool-use loop.',
  };

  for (final entry in dummySummaries.entries) {
    // Use a stable hash derived from the summary itself as the content hash.
    final hash = CodeHasher.hashText(entry.value);
    graph.setSummary(entry.key, hash, entry.value);
  }

  // Save so the round-trip is verified.
  GraphStore.save(graph, repoRoot);
  print('Saved graph with ${graph.summaries.length} summaries to .tina/graph.json\n');

  // Reload and verify round-trip.
  final loaded = GraphStore.load(repoRoot);
  assert(loaded != null, 'graph failed to load');
  for (final entry in dummySummaries.entries) {
    final got = loaded!.summaryFor(entry.key);
    assert(got == entry.value, 'Summary mismatch for ${entry.key}');
  }
  print('Round-trip verified: all ${dummySummaries.length} summaries survived save/load\n');

  // Expand from Agent and display with summaries.
  final result = GraphTraversal.expand(
    loaded!,
    ['lib/agent/agent.Agent'],
    hops: 2,
    repoRoot: repoRoot,
  );

  print('2-hop expansion from Agent (${result.nodes.length} nodes):');
  for (final id in result.nodes.keys) {
    final sym = result.nodes[id]!;
    final relPath = p.relative(sym.filePath, from: repoRoot);
    final summary = loaded.summaryFor(relPath);

    final edges = result.edges
        .where((e) => e.fromId == id || e.toId == id)
        .map((e) {
      if (e.fromId == id) return '→ ${e.kind.name}: ${e.toId}';
      return '← ${e.kind.name}: ${e.fromId}';
    }).join(', ');

    print('  $id (${sym.kind.name}${sym.isAbstract ? ', abstract' : ''})');
    if (summary != null) print('    [$summary]');
    if (edges.isNotEmpty) print('    $edges');
  }
}
