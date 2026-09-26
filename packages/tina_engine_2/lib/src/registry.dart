/// The plugin registry: registration, removal, and the stable run order.
library;

import 'dart:collection';

import 'plugin.dart';

/// Holds plugins in registration order and answers "who runs, in what
/// order". A duplicate id is a programming error: it throws at
/// registration, not later in a turn.
final class PluginRegistry {
  final LinkedHashMap<String, AgentPlugin> _byId = LinkedHashMap();

  /// Register a plugin. Throws [ArgumentError] on a duplicate id.
  void add(AgentPlugin plugin) {
    if (_byId.containsKey(plugin.id)) {
      throw ArgumentError('duplicate plugin id: ${plugin.id}');
    }
    _byId[plugin.id] = plugin;
  }

  /// Remove a plugin. Dispatch re-checks liveness, so a removed plugin's
  /// pending tool call is skipped, not crashed on.
  void remove(String id) => _byId.remove(id);

  bool contains(String id) => _byId.containsKey(id);

  /// Run order: ascending [AgentPlugin.order], ties broken by id, so the
  /// sequence is the same every run.
  List<AgentPlugin> inOrder() {
    final list = _byId.values.toList()
      ..sort((a, b) => a.order != b.order
          ? a.order.compareTo(b.order)
          : a.id.compareTo(b.id));
    return list;
  }
}

/// Runs one plugin hook in isolation. A plugin that throws has its
/// contribution treated as absent; the turn continues. One bad plugin must
/// never break a turn or a prompt.
T? runHook<T>(T? Function() hook) {
  try {
    return hook();
  } catch (_) {
    return null;
  }
}
