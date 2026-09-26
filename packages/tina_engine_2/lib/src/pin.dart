/// Tool pinning: the set is read once at the turn boundary and must not
/// change during the turn.
library;

import 'plugin.dart';
import 'model.dart';

/// The tool set pinned at the turn boundary, plus its owner map.
final class PinnedTools {
  PinnedTools(List<AgentPlugin> pluginsInOrder)
      : byName = {
          for (final p in pluginsInOrder)
            for (final t in p.tools) t.name: t
        },
        ownerOf = {
          for (final p in pluginsInOrder)
            for (final t in p.tools) t.name: p.id
        };

  /// Tool name -> tool, pinned once per turn.
  final Map<String, Tool> byName;

  /// Tool name -> owning plugin id.
  final Map<String, String> ownerOf;

  /// The pinned tools, in a stable order.
  List<Tool> get list => byName.values.toList();

  /// True if the live plugin list still matches the *live* pinned set. A
  /// plugin that left is not a change — its tools simply became
  /// undispatchable, which the liveness check handles. Any other difference
  /// is a broken invariant.
  bool stillValid({
    required List<AgentPlugin> Function() pluginsInOrder,
    required bool Function(String pluginId) isLive,
  }) {
    final livePinned = {
      for (final name in byName.keys)
        if (isLive(ownerOf[name]!)) name
    };
    final now = {
      for (final p in pluginsInOrder())
        for (final t in p.tools) t.name
    };
    return now.length == livePinned.length && now.containsAll(livePinned);
  }
}
