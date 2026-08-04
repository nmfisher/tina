import 'edge.dart';
import 'symbol_table.dart';

class CodeGraph {
  final SymbolTable symbols;
  final List<Edge> edges;

  /// Content hash → summary text. Append-only; entries are never deleted.
  final Map<String, String> summaries;

  /// Qualified name or file path → content hash. Ephemeral; maps current
  /// names to their content hash for fast summary lookup.
  final Map<String, String> manifest;

  final Map<String, List<Edge>> _edgesFrom = {};
  final Map<String, List<Edge>> _edgesTo = {};

  CodeGraph({
    required this.symbols,
    required this.edges,
    Map<String, String>? summaries,
    Map<String, String>? manifest,
  })  : summaries = summaries ?? {},
        manifest = manifest ?? {} {
    for (final e in edges) {
      _index(e);
    }
  }

  List<Edge> edgesFrom(String id) => _edgesFrom[id] ?? const [];
  List<Edge> edgesTo(String id) => _edgesTo[id] ?? const [];

  void addEdge(Edge e) {
    edges.add(e);
    _index(e);
  }

  /// Look up a summary by qualified name or file path.
  /// Performs a two-step lookup: manifest[key] → summaries[hash].
  String? summaryFor(String key) {
    final hash = manifest[key];
    if (hash == null) return null;
    return summaries[hash];
  }

  /// Store a summary and register it in the manifest.
  void setSummary(String key, String hash, String summary) {
    manifest[key] = hash;
    summaries[hash] = summary;
  }

  /// Register a manifest entry pointing to an existing hash.
  void setContentHash(String key, String hash) {
    manifest[key] = hash;
  }

  /// Check whether a summary exists for the given content hash.
  bool hasSummary(String hash) => summaries.containsKey(hash);

  void removeEdgesWhere(bool Function(Edge e) test) {
    edges.removeWhere(test);
    _rebuild();
  }

  void _index(Edge e) {
    _edgesFrom.putIfAbsent(e.fromId, () => []).add(e);
    _edgesTo.putIfAbsent(e.toId, () => []).add(e);
  }

  void _rebuild() {
    _edgesFrom.clear();
    _edgesTo.clear();
    for (final e in edges) {
      _index(e);
    }
  }
}
