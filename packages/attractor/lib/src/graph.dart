import 'outcome.dart';

/// A typed attribute value parsed from a DOT attribute block. The DOT subset
/// allows quoted strings, integers, floats, booleans, durations, and bare
/// identifiers; the parser keeps the native type so node getters stay precise.
typedef AttrValue = Object; // String | int | double | bool

/// One node in the pipeline graph. The raw DOT attributes live in [attrs];
/// typed getters are provided for the attributes the engine and handlers
/// actually consult.
class PipelineNode {
  final String id;

  /// Raw DOT attributes in parse order. Values are [String], [int], [double],
  /// or [bool].
  final Map<String, AttrValue> attrs;

  PipelineNode({required this.id, Map<String, AttrValue>? attrs})
      : attrs = attrs ?? {};

  /// Display name. Falls back to the node id when unset (DOT default).
  String get label => (attrs['label'] as String?) ?? id;

  /// Graphviz shape — determines the handler type unless [type] is set.
  String get shape => (attrs['shape'] as String?) ?? 'box';

  /// Explicit handler-type override (takes precedence over [shape]).
  String get type => (attrs['type'] as String?) ?? '';

  /// The task instruction for an LLM node. Falls back to [label] when empty
  /// (after `$goal` expansion).
  String get prompt => (attrs['prompt'] as String?) ?? '';

  /// The node's identity prose — its system prompt. Read from the
  /// `system_prompt` attribute, with `instructions` accepted as an alias.
  /// Empty means "the host applies its default identity". A node no longer
  /// resolves a role for its identity (tin-80ll).
  String get systemPrompt =>
      (attrs['system_prompt'] as String?) ??
      (attrs['instructions'] as String?) ??
      '';

  /// The node's model id, e.g. `"claude-sonnet-4-6"`. Paired with
  /// [llmProvider] via [modelReference]. Empty means "inherit the
  /// conversation's model".
  String get llmModel => (attrs['llm_model'] as String?) ?? '';

  /// The node's provider id, e.g. `"anthropic"`. Paired with [llmModel] via
  /// [modelReference]. Empty means "inherit the conversation's model".
  String get llmProvider => (attrs['llm_provider'] as String?) ?? '';

  /// The combined `"provider/model"` reference for this node's agent, built
  /// from [llmProvider] + [llmModel]. Empty unless both are set, in which case
  /// the host inherits the conversation's resolved model.
  String get modelReference {
    if (llmProvider.isEmpty || llmModel.isEmpty) return '';
    return '$llmProvider/$llmModel';
  }

  /// Whether this node must reach success before the pipeline can exit.
  bool get goalGate => _bool(attrs['goal_gate'], false);

  /// Additional attempts beyond the first (so `3` = 4 total executions).
  /// null = inherit the graph's `default_max_retries`.
  int? get maxRetries => _int(attrs['max_retries']);

  /// Node to jump to if this node fails and retries are exhausted. v1 always
  /// retries the same node; this is parsed for forward compatibility.
  String get retryTarget => (attrs['retry_target'] as String?) ?? '';

  /// Accept PARTIAL_SUCCESS when retries are exhausted instead of failing.
  bool get allowPartial => _bool(attrs['allow_partial'], false);

  /// If true and the handler writes no status, auto-generate a SUCCESS outcome.
  bool get autoStatus => _bool(attrs['auto_status'], false);

  /// The handler type this node resolves to: explicit [type], else the
  /// shape-to-type mapping, else `codergen` (the default).
  String get handlerType => type.isNotEmpty
      ? type
      : shapeToHandlerType(shape) ?? 'codergen';

  bool _bool(Object? v, bool d) => v is bool ? v : d;

  int? _int(Object? v) => v is int ? v : null;

  @override
  String toString() => 'PipelineNode($id)';
}

/// One directed edge between nodes.
class PipelineEdge {
  final String from;
  final String to;

  /// Human-facing caption AND routing key (edge-selection step 2 matches this
  /// against an outcome's `preferred_label`).
  final String label;

  /// Boolean guard expression, e.g. `outcome=success && context.x=y`. Empty
  /// means unconditional.
  final String condition;

  /// Numeric priority among equally eligible unconditional edges (step 4).
  final int weight;

  /// Raw DOT attributes.
  final Map<String, AttrValue> attrs;

  PipelineEdge({
    required this.from,
    required this.to,
    this.label = '',
    this.condition = '',
    this.weight = 0,
    Map<String, AttrValue>? attrs,
  }) : attrs = attrs ?? {};

  bool get hasCondition => condition.isNotEmpty;
  bool get hasLabel => label.isNotEmpty;

  @override
  String toString() => '$from -> $to'
      '${label.isNotEmpty ? ' [label="$label"]' : ''}';
}

/// The parsed pipeline: a named directed graph with graph-level attributes,
/// nodes, and edges.
class Graph {
  /// The `digraph` identifier.
  final String name;

  /// Graph-level attributes (`goal`, `label`, `default_max_retries`,
  /// `default_fidelity`, `retry_target`, …).
  final Map<String, AttrValue> attrs;

  /// Nodes keyed by id, in declaration order.
  final Map<String, PipelineNode> nodes;

  /// Edges in declaration order.
  final List<PipelineEdge> edges;

  Graph({
    required this.name,
    Map<String, AttrValue>? attrs,
    Map<String, PipelineNode>? nodes,
    List<PipelineEdge>? edges,
  })  : attrs = attrs ?? {},
        nodes = nodes ?? {},
        edges = edges ?? [];

  PipelineNode? node(String id) => nodes[id];

  /// Outgoing edges of [nodeId], in declaration order.
  List<PipelineEdge> outgoing(String nodeId) =>
      edges.where((e) => e.from == nodeId).toList();

  /// Incoming edges of [nodeId].
  List<PipelineEdge> incoming(String nodeId) =>
      edges.where((e) => e.to == nodeId).toList();

  // -- Graph-level typed getters -------------------------------------------

  String get goal => (attrs['goal'] as String?) ?? '';

  String get graphLabel => (attrs['label'] as String?) ?? name;

  int get defaultMaxRetries {
    final v = attrs['default_max_retries'] ?? attrs['default_max_retry'];
    return v is int ? v : 0;
  }

  /// The start node: the single `Mdiamond` node (else one whose id is
  /// `start` / `Start`). null if none.
  PipelineNode? findStartNode() {
    final diamond =
        nodes.values.where((n) => n.shape == 'Mdiamond').toList();
    if (diamond.length == 1) return diamond.first;
    for (final alt in const ['start', 'Start']) {
      final n = nodes[alt];
      if (n != null) return n;
    }
    return diamond.isNotEmpty ? diamond.first : null;
  }

  /// Whether a node is the pipeline exit (shape `Msquare` or id
  /// `exit`/`end`).
  bool isTerminal(PipelineNode n) =>
      n.shape == 'Msquare' ||
      n.id == 'exit' ||
      n.id == 'end';

  /// Terminal nodes (shape Msquare).
  List<PipelineNode> get terminalNodes =>
      nodes.values.where(isTerminal).toList();
}

/// Canonical shape -> handler-type mapping (spec §2.8). Returns null for an
/// unrecognized shape, so the node falls back to the `codergen` default (and
/// the validator emits a warning).
String? shapeToHandlerType(String shape) {
  switch (shape) {
    case 'Mdiamond':
      return 'start';
    case 'Msquare':
      return 'exit';
    case 'box':
      return 'codergen';
    case 'hexagon':
      return 'wait.human';
    case 'diamond':
      return 'conditional';
    case 'component':
      return 'parallel';
    case 'tripleoctagon':
      return 'parallel.fan_in';
    case 'parallelogram':
      return 'tool';
    case 'house':
      return 'stack.manager_loop';
    default:
      return null;
  }
}

/// A stand-in used by the start/exit handlers and tests.
Outcome noopOutcome(String nodeId) =>
    Outcome.success(notes: 'no-op node: $nodeId');
