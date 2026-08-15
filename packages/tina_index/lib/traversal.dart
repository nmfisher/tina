import 'dart:io';

import 'package:path/path.dart' as p;

import 'edge.dart';
import 'graph.dart';
import 'symbol.dart';

class Subgraph {
  final Map<String, Symbol> nodes;
  final List<Edge> edges;

  Subgraph({required this.nodes, required this.edges});
}

class GraphTraversal {
  static const defaultMaxNodes = 50;

  /// Expand [seeds] bidirectionally through [graph] up to [hops] hops.
  /// Seeds can be symbol qualified names (e.g. "lib/agent/agent.Agent")
  /// or file paths (e.g. "lib/agent/agent.dart").
  static Subgraph expand(
    CodeGraph graph,
    List<String> seeds, {
    int hops = 2,
    int maxNodes = defaultMaxNodes,
    String? repoRoot,
  }) {
    // Infer repoRoot from the graph if not provided.
    final root = repoRoot ?? _inferRepoRoot(graph);
    final visited = <String>{};
    final frontier = <String>{...seeds};
    final resultEdges = <Edge>[];

    // Collect seed symbols.
    final resultNodes = <String, Symbol>{};
    for (final seed in seeds) {
      final s = graph.symbols[seed];
      if (s != null) resultNodes[seed] = s;
    }

    // Interface-consumer expansion on seeds: if a seed is abstract,
    // pull in all implementors immediately. Seeds themselves are always
    // kept (the caller asked for them), but discovered consumers respect
    // maxNodes — an interface with many implementors must not blow past
    // the cap before the hop loop's own checks even run.
    for (final seed in seeds) {
      final s = graph.symbols[seed];
      if (s != null && s.isAbstract) {
        for (final e in graph.edgesTo(seed)) {
          if (e.kind == EdgeKind.extends_ ||
              e.kind == EdgeKind.implements_) {
            final impl = graph.symbols[e.fromId];
            if (impl != null &&
                !resultNodes.containsKey(e.fromId) &&
                resultNodes.length < maxNodes) {
              resultNodes[e.fromId] = impl;
              frontier.add(e.fromId);
            }
            resultEdges.add(e);
          }
        }
      }
    }

    for (int hop = 0; hop < hops; hop++) {
      final nextFrontier = <String>{};
      for (final id in frontier) {
        if (visited.contains(id)) continue;
        visited.add(id);

        // Follow edges from this node (symbol or file).
        for (final e in graph.edgesFrom(id)) {
          resultEdges.add(e);
          _expandInto(e.toId, graph, resultNodes, nextFrontier, visited, maxNodes);
        }

        // Follow edges to this node.
        for (final e in graph.edgesTo(id)) {
          resultEdges.add(e);
          _expandInto(e.fromId, graph, resultNodes, nextFrontier, visited, maxNodes);
        }

        // Bridge: if id is a symbol, also follow edges from its file path.
        final sym = graph.symbols[id];
        if (sym != null) {
          final relPath = p.relative(sym.filePath, from: root);
          if (!visited.contains(relPath)) {
            for (final e in graph.edgesFrom(relPath)) {
              resultEdges.add(e);
              // For import edges, expand into symbols in the target file immediately.
              if (e.kind == EdgeKind.imports || e.kind == EdgeKind.exports) {
                _expandFileSymbols(e.toId, graph, resultNodes, visited, root, maxNodes);
              } else {
                _expandInto(e.toId, graph, resultNodes, nextFrontier, visited, maxNodes);
              }
            }
          }
        }

        // Bridge: if id is a file path, expand into all symbols in that file.
        for (final qName in graph.symbols.qualifiedNames) {
          if (resultNodes.length >= maxNodes) break;
          if (resultNodes.containsKey(qName)) continue;
          final s = graph.symbols[qName]!;
          final relPath = p.relative(s.filePath, from: root);
          if (relPath == id && !visited.contains(qName)) {
            resultNodes[qName] = s;
            nextFrontier.add(qName);
          }
        }

        // Interface-consumer expansion: if this symbol is abstract,
        // pull in all symbols that extend/implement it.
        if (sym != null && sym.isAbstract) {
          for (final e in graph.edgesTo(id)) {
            if (e.kind == EdgeKind.extends_ ||
                e.kind == EdgeKind.implements_) {
              _expandInto(
                  e.fromId, graph, resultNodes, nextFrontier, visited, maxNodes);
              if (!resultEdges.contains(e)) resultEdges.add(e);
            }
          }
        }
      }
      frontier.addAll(nextFrontier);
      if (resultNodes.length >= maxNodes) break;
    }

    visited.addAll(frontier);
    return Subgraph(nodes: resultNodes, edges: resultEdges);
  }

  /// When an edge targets a file or symbol, try to add it and its symbols.
  static void _expandInto(
    String id,
    CodeGraph graph,
    Map<String, Symbol> nodes,
    Set<String> frontier,
    Set<String> visited,
    int maxNodes,
  ) {
    if (nodes.length >= maxNodes) return;

    // If it's a symbol, add it directly.
    final s = graph.symbols[id];
    if (s != null) {
      if (!visited.contains(id) && !nodes.containsKey(id)) {
        nodes[id] = s;
        frontier.add(id);
      }
      return;
    }

    // If it's a file path, add it to the frontier for next-hop expansion.
    if (!visited.contains(id)) {
      frontier.add(id);
    }
  }

  /// Expand all symbols within a file into resultNodes.
  static void _expandFileSymbols(
    String filePath,
    CodeGraph graph,
    Map<String, Symbol> nodes,
    Set<String> visited,
    String repoRoot,
    int maxNodes,
  ) {
    for (final qName in graph.symbols.qualifiedNames) {
      if (nodes.length >= maxNodes) break;
      if (nodes.containsKey(qName)) continue;
      final s = graph.symbols[qName]!;
      final relPath = p.relative(s.filePath, from: repoRoot);
      if (relPath == filePath) {
        nodes[qName] = s;
        visited.add(qName);
      }
    }
  }

  static String _inferRepoRoot(CodeGraph graph) {
    // Infer repo root from the first symbol's file path.
    // This is a bit hacky but avoids passing repoRoot through expand().
    for (final s in graph.symbols.all) {
      final parts = p.split(s.filePath);
      final libIdx = parts.indexOf('lib');
      if (libIdx > 0) {
        return p.joinAll(parts.sublist(0, libIdx));
      }
    }
    return Directory.current.path;
  }

  /// Read source text for a symbol from its file.
  static String? readSource(Symbol symbol) {
    final file = File(symbol.filePath);
    if (!file.existsSync()) return null;
    final lines = file.readAsStringSync().split('\n');
    if (symbol.lineStart < 1 || symbol.lineEnd > lines.length) return null;
    return lines.sublist(symbol.lineStart - 1, symbol.lineEnd).join('\n');
  }
}
