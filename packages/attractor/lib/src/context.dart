/// A snapshot entry in the run [Context] — preserves insertion order so the
/// preamble builder can render prior-node outputs in the order they were
/// produced.
class ContextEntry {
  final String key;
  final String value;
  const ContextEntry(this.key, this.value);
}

/// The shared key-value store for a pipeline run. It is the primary mechanism
/// for passing data between nodes: a handler reads prior values and returns
/// `context_updates` in its [Outcome], which the engine merges back.
///
/// Values are strings. The engine mirrors graph attributes (e.g. `graph.goal`)
/// and bookkeeping (`outcome`, `preferred_label`, `current_node`,
/// `internal.retry_count.<id>`) into the context at run time. Node handlers
/// store each node's full output under `context.<nodeId>` so downstream nodes'
/// preambles can include it.
///
/// Traversal is single-threaded in v1, so this is a plain ordered map; the
/// read/write locking the spec describes is reserved for the parallel-handler
/// phase.
class Context {
  final Map<String, String> _values;

  Context() : _values = {};

  /// Build a context pre-seeded with [values] (insertion ordered).
  Context.from(Map<String, String> values) : _values = {...values};

  void set(String key, String value) => _values[key] = value;

  void setBool(String key, bool value) => _values[key] = value.toString();

  void setInt(String key, int value) => _values[key] = value.toString();

  String? get(String key) => _values[key];

  String getString(String key, [String defaultValue = '']) =>
      _values[key] ?? defaultValue;

  bool getBool(String key, [bool defaultValue = false]) {
    final v = _values[key];
    return v == null ? defaultValue : v == 'true';
  }

  int getInt(String key, [int defaultValue = 0]) =>
      int.tryParse(_values[key] ?? '') ?? defaultValue;

  bool contains(String key) => _values.containsKey(key);

  bool get isEmpty => _values.isEmpty;

  bool get isNotEmpty => _values.isNotEmpty;

  /// All entries in insertion order.
  Iterable<ContextEntry> get orderedEntries =>
      _values.entries.map((e) => ContextEntry(e.key, e.value));

  /// The keys the engine itself manages — a preamble should skip these when
  /// assembling prior-work context.
  static const internalKeys = <String>{
    'outcome',
    'preferred_label',
    'current_node',
    'last_stage',
    'last_response',
    'graph.goal',
    'history',
  };

  /// Merge a batch of updates (an [Outcome]'s `context_updates`).
  void applyUpdates(Map<String, String> updates) => _values.addAll(updates);

  /// A deep copy, for parallel-branch isolation (used by the parallel handler).
  Context clone() => Context.from(_values);

  /// A serializable snapshot.
  Map<String, String> snapshot() => {..._values};
}
