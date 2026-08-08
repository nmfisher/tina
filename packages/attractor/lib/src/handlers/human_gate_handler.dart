import '../interviewer.dart';
import '../node_handler.dart';

/// A human-in-the-loop gate (`hexagon`). Presents the node's outgoing edges as
/// choices via the [Interviewer], then routes on the selection: the chosen
/// edge's target becomes [Outcome.suggestedNextIds] (and its label becomes
/// [Outcome.preferredLabel]).
class HumanGateHandler implements NodeHandler {
  final Interviewer interviewer;

  HumanGateHandler(this.interviewer);

  @override
  Future<Outcome> execute({
    required PipelineNode node,
    required Graph graph,
    required Context context,
    required RunStore runStore,
    Future<void>? cancelSignal,
    PipelineEventListener? onEvent,
  }) async {
    final edges = graph.outgoing(node.id);
    if (edges.isEmpty) {
      return Outcome.fail('no outgoing edges for human gate "${node.id}"');
    }

    // Derive one choice per outgoing edge.
    final choices = <_Choice>[];
    for (final e in edges) {
      final label = e.hasLabel ? e.label : e.to;
      choices.add(_Choice(
        key: parseAccelerator(label),
        label: label,
        to: e.to,
      ));
    }
    final options =
        choices.map((c) => Option(key: c.key, label: c.label)).toList();

    final question = Question(
      text: node.label == node.id ? 'Select an option:' : node.label,
      type: QuestionType.multipleChoice,
      options: options,
      stage: node.id,
    );

    final answer = await interviewer.ask(question);
    if (answer.isCancelled) {
      return Outcome.fail('human skipped gate "${node.id}"');
    }

    // Match the answer to a choice (by key, then label, else first).
    final selected = _matchChoice(answer, choices) ?? choices.first;

    await runStore.writeNode(
      nodeId: node.id,
      outcome: Outcome.success(
        preferredLabel: selected.label,
        suggestedNextIds: [selected.to],
        contextUpdates: {
          'human.gate.selected': selected.key,
          'human.gate.label': selected.label,
        },
        notes: 'human chose "${selected.label}" -> ${selected.to}',
      ),
      prompt: question.text,
      response: selected.label,
    );

    return Outcome.success(
      preferredLabel: selected.label,
      suggestedNextIds: [selected.to],
      contextUpdates: {
        'human.gate.selected': selected.key,
        'human.gate.label': selected.label,
      },
      notes: 'human chose "${selected.label}" -> ${selected.to}',
    );
  }

  _Choice? _matchChoice(Answer answer, List<_Choice> choices) {
    final key = answer.value ?? answer.selectedOption?.key;
    if (key != null) {
      final byKey = choices.where((c) => c.key == key);
      if (byKey.isNotEmpty) return byKey.first;
    }
    final label = answer.routeLabel;
    if (label != null) {
      final byLabel = choices.where((c) => c.label == label);
      if (byLabel.isNotEmpty) return byLabel.first;
    }
    return null;
  }
}

class _Choice {
  final String key;
  final String label;
  final String to;
  const _Choice({required this.key, required this.label, required this.to});
}

/// Extract a shortcut key from an edge label: `[Y] …`, `Y) …`, `Y - …`, else
/// the first character.
String parseAccelerator(String label) {
  final trimmed = label.trim();
  if (trimmed.isEmpty) return '?';
  final bracket = RegExp(r'^\[([A-Za-z0-9])\]').firstMatch(trimmed);
  if (bracket != null) return bracket.group(1)!.toUpperCase();
  final paren = RegExp(r'^([A-Za-z0-9])\)').firstMatch(trimmed);
  if (paren != null) return paren.group(1)!.toUpperCase();
  final dash = RegExp(r'^([A-Za-z0-9])\s*[-—]').firstMatch(trimmed);
  if (dash != null) return dash.group(1)!.toUpperCase();
  return trimmed[0].toUpperCase();
}
