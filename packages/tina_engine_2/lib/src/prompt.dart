/// The system prompt: the core's header, then plugin sections in order.
/// The join belongs to the core — a plugin returns one section, never a
/// whole prompt.
library;

import 'context.dart';
import 'model.dart';
import 'plugin.dart';

/// Assembles the system prompt for one request.
final class PromptBuilder {
  PromptBuilder({
    required List<AgentPlugin> Function() pluginsInOrder,
    required Context Function(List<Tool> pinned) snapshot,
    this.header = 'You are tina, a terminal coding agent.',
  })  : _pluginsInOrder = pluginsInOrder,
        _snapshot = snapshot;

  final List<AgentPlugin> Function() _pluginsInOrder;
  final Context Function(List<Tool> pinned) _snapshot;
  final String header;

  /// Sections in ascending plugin order, joined by one blank line. A
  /// throwing plugin is isolated: its section is absent.
  String build(List<Tool> pinned) {
    final sections = <String>[header];
    for (final p in _pluginsInOrder()) {
      try {
        final section = p.systemSection(_snapshot(pinned));
        if (section != null && section.isNotEmpty) sections.add(section);
      } catch (_) {
        // one bad plugin must not break every prompt
      }
    }
    return sections.join('\n\n');
  }
}
