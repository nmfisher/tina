import 'dart:io';

import 'package:tina_index/tina_index.dart';
import 'package:path/path.dart' as p;
import 'tool.dart';

class SearchTool implements Tool {
  final String repoRoot;
  CodeGraph? _graph;

  SearchTool({String? repoRoot})
      : repoRoot = repoRoot ?? Directory.current.path;

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'search',
        description:
            'Search the code dependency graph for a symbol. Returns related '
            'symbols, their relationships (extends, implements, imports), and '
            'source code. Use qualified names like "LlmProvider" or '
            '"agent/agent.Agent".',
        inputSchema: {
          'type': 'object',
          'properties': {
            'symbol': {
              'type': 'string',
              'description':
                  "Qualified symbol name (e.g. 'LlmProvider', "
                  "'agent/agent.Agent')",
            },
          },
          'required': ['symbol'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final symbol = input['symbol'] as String?;
    if (symbol == null || symbol.isEmpty) {
      return ToolResult.error('symbol is required');
    }

    final graph = _loadGraph();
    if (graph == null) {
      return ToolResult.error('Failed to build dependency graph');
    }

    // Try exact match first, then fuzzy by name suffix, then keyword seeding.
    var seeds = _resolveSeeds(graph, symbol);
    if (seeds.isEmpty) {
      // Fall back to keyword seeding for natural language queries.
      seeds = seedQuery(graph.symbols, symbol);
    }
    if (seeds.isEmpty) {
      return ToolResult(
          'No symbol matching "$symbol" found in the dependency graph.');
    }

    final subgraph = GraphTraversal.expand(graph, seeds, hops: 2);

    final out = StringBuffer();
    out.writeln('Symbols matching "${symbol}":');
    for (final entry in subgraph.nodes.entries) {
      final qName = entry.key;
      final sym = entry.value;
      out.writeln();
      out.writeln('── $qName (${sym.kind.name}${sym.isAbstract ? ', abstract' : ''}) ──');

      // Show symbol-level summary, falling back to file-level.
      final symbolSummary = graph.summaryFor(qName);
      if (symbolSummary != null) {
        out.writeln('  [$symbolSummary]');
      } else {
        final relPath = p.relative(sym.filePath, from: repoRoot);
        final fileSummary = graph.summaryFor(relPath);
        if (fileSummary != null) {
          out.writeln('  [$fileSummary]');
        }
      }

      // Show member summaries for classes/mixins.
      if (sym.kind == SymbolKind.class_ || sym.kind == SymbolKind.mixin) {
        final memberLines = <String>[];
        for (final me in graph.symbols.entries.entries) {
          if (me.value.filePath != sym.filePath ||
              me.value.parentName != sym.name) continue;
          final ms = graph.summaryFor(me.key);
          if (ms != null) {
            memberLines.add('    ${me.value.name}: $ms');
          }
        }
        if (memberLines.isNotEmpty) out.writeln('  Members:');
        for (final line in memberLines) {
          out.writeln(line);
        }
      }

      // Show relationships.
      final edges = subgraph.edges.where(
          (e) => e.fromId == qName || e.toId == qName);
      for (final e in edges) {
        if (e.fromId == qName) {
          out.writeln('  → ${e.kind.name}: ${e.toId}');
        } else {
          out.writeln('  ← ${e.kind.name}: ${e.fromId}');
        }
      }

      // Show source text (capped).
      final source = GraphTraversal.readSource(sym);
      if (source != null && source.length <= 2000) {
        out.writeln();
        for (final line in source.split('\n')) {
          out.writeln('  $line');
        }
      }
    }

    if (out.length > 8000) {
      return ToolResult(out.toString().substring(0, 8000) +
          '\n\n... (truncated; ${subgraph.nodes.length} symbols total)');
    }
    return ToolResult(out.toString());
  }

  CodeGraph? _loadGraph() {
    if (_graph != null) return _graph;
    _graph = GraphStore.load(repoRoot) ?? GraphStore.rebuildFromRepo(repoRoot);
    return _graph;
  }

  List<String> _resolveSeeds(CodeGraph graph, String symbol) {
    // Exact qualified name match.
    if (graph.symbols[symbol] != null) return [symbol];

    // Try matching as a file path.
    if (symbol.endsWith('.dart')) return [symbol];

    // Match by suffix: "Agent" matches "lib/agent/agent.Agent".
    final matches = graph.symbols.qualifiedNames
        .where((q) => q.endsWith('.$symbol') || q.endsWith('/$symbol'))
        .toList();
    if (matches.isNotEmpty) return matches;

    // Try matching by name anywhere in the qualified name.
    return graph.symbols.qualifiedNames
        .where((q) => q.contains(symbol))
        .toList();
  }
}
