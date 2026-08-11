import 'graph.dart';

/// Serialize a [Graph] back to DOT source. Round-trips through [parseDot]:
/// `parseDot(graphToDot(g))` recovers the same structure (graph attrs, nodes,
/// edges, and their attributes). Required by the visual editor's Save.
///
/// Only the attributes the engine/parser cares about are emitted specially
/// (with quoting and default-skipping); any other raw attribute in a node or
/// edge's [PipelineNode.attrs] / [PipelineEdge.attrs] map is emitted verbatim
/// (strings quoted, numbers bare) so hand-added attrs survive a round trip.
String graphToDot(Graph g) {
  final buf = StringBuffer();
  buf.writeln('digraph ${_safeIdent(g.name, 'pipeline')} {');

  // Graph-level attributes.
  final graphAttrs = <String, AttrValue>{...g.attrs};
  if (graphAttrs.isNotEmpty) {
    buf.writeln('  graph [${_attrs(graphAttrs)}]');
  }

  // Nodes, in declaration order.
  for (final n in g.nodes.values) {
    final id = _safeIdent(n.id, n.id);
    final attrs = <String, AttrValue>{...n.attrs};
    // Ensure label is emitted even when it equals the id (so round-trip keeps
    // the display name), unless attrs never had one.
    if (n.label != n.id && !attrs.containsKey('label')) {
      attrs['label'] = n.label;
    }
    if (attrs.isEmpty) {
      buf.writeln('  $id;');
    } else {
      buf.writeln('  $id [${_attrs(attrs)}]');
    }
  }

  // Edges.
  for (final e in g.edges) {
    final from = _safeIdent(e.from, e.from);
    final to = _safeIdent(e.to, e.to);
    final attrs = <String, AttrValue>{...e.attrs};
    if (e.label.isNotEmpty && !attrs.containsKey('label')) {
      attrs['label'] = e.label;
    }
    if (e.condition.isNotEmpty && !attrs.containsKey('condition')) {
      attrs['condition'] = e.condition;
    }
    if (e.weight != 0 && !attrs.containsKey('weight')) {
      attrs['weight'] = e.weight;
    }
    if (attrs.isEmpty) {
      buf.writeln('  $from -> $to;');
    } else {
      buf.writeln('  $from -> $to [${_attrs(attrs)}]');
    }
  }

  buf.writeln('}');
  return buf.toString();
}

String _attrs(Map<String, AttrValue> attrs) {
  // Stable, readable order: the well-known keys first, then the rest sorted.
  const order = [
    'shape', 'label', 'system_prompt', 'instructions', 'llm_model',
    'llm_provider', 'prompt', 'context', 'writes', 'goal_gate',
    'max_retries', 'retry_target', 'allow_partial', 'auto_status', 'type',
    'condition', 'weight', 'rankdir', 'goal',
  ];
  final keys = <String>[
    ...order.where(attrs.containsKey),
    ...(attrs.keys.where((k) => !order.contains(k)).toList()..sort()),
  ];
  return keys.map((k) => '$k=${_formatValue(k, attrs[k]!)}').join(', ');
}

String _formatValue(String key, AttrValue v) {
  if (v is bool) return v ? 'true' : 'false';
  if (v is int || v is double) return '$v';
  // String (or anything else) — quote it.
  return '"${_escape(v.toString())}"';
}

String _escape(String s) =>
    s.replaceAll(r'\', r'\\').replaceAll('"', r'\"').replaceAll('\n', r'\n');

/// Bare DOT identifiers must match [A-Za-z_][A-Za-z0-9_]*. The parser only
/// accepts bare ids (not quoted), so a programmatically-built id (from the
/// editor) that doesn't match is sanitized: invalid runs → `_`, and a non-alpha
/// first char is prefixed with `n_`. Valid ids pass through unchanged.
String _safeIdent(String id, String fallback) {
  var s = id.isEmpty ? fallback : id;
  final sanitized = s.replaceAll(RegExp(r'[^A-Za-z0-9_]'), '_');
  if (sanitized.isEmpty || RegExp(r'^[0-9]').hasMatch(sanitized)) {
    return 'n_$sanitized';
  }
  return sanitized;
}
