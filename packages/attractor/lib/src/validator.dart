import 'dart:collection';

import 'condition.dart';
import 'graph.dart';

/// How loud a [Diagnostic] is. [error] blocks execution; [warning]/[info] do not.
enum Severity { error, warning, info }

class Diagnostic {
  final String rule;
  final Severity severity;
  final String message;

  /// Related node id, when applicable.
  final String? nodeId;

  const Diagnostic({
    required this.rule,
    required this.severity,
    required this.message,
    this.nodeId,
  });

  @override
  String toString() {
    final where = nodeId == null ? '' : ' ($nodeId)';
    return '${severity.name.toUpperCase()} [$rule]$where: $message';
  }
}

/// Validate a parsed [Graph]. Returns diagnostics ordered by severity (errors
/// first). A codergen node carries its own `system_prompt`/`llm_model`/
/// `llm_provider` attributes (tin-80ll), so there are no role names to check.
List<Diagnostic> validate(Graph graph) {
  final diags = <Diagnostic>[];

  final start = graph.findStartNode();
  final diamonds = graph.nodes.values.where((n) => n.shape == 'Mdiamond');
  if (diamonds.length != 1 && start == null) {
    diags.add(const Diagnostic(
      rule: 'start_node',
      severity: Severity.error,
      message: 'pipeline must have exactly one start node '
          '(shape=Mdiamond, or id "start")',
    ));
  } else if (diamonds.length > 1) {
    diags.add(Diagnostic(
      rule: 'start_node',
      severity: Severity.error,
      message: 'pipeline has ${diamonds.length} start nodes; expected one',
    ));
  }

  final terminals = graph.terminalNodes;
  if (terminals.isEmpty) {
    diags.add(const Diagnostic(
      rule: 'terminal_node',
      severity: Severity.error,
      message: 'pipeline must have exactly one exit node '
          '(shape=Msquare, or id "exit"/"end")',
    ));
  } else if (terminals.length > 1) {
    diags.add(Diagnostic(
      rule: 'terminal_node',
      severity: Severity.error,
      message: 'pipeline has ${terminals.length} exit nodes; expected one',
    ));
  }

  // Edge targets exist.
  for (final e in graph.edges) {
    if (!graph.nodes.containsKey(e.from)) {
      diags.add(Diagnostic(
          rule: 'edge_target_exists',
          severity: Severity.error,
          message: 'edge source "$e" references unknown node "${e.from}"'));
    }
    if (!graph.nodes.containsKey(e.to)) {
      diags.add(Diagnostic(
          rule: 'edge_target_exists',
          severity: Severity.error,
          message: 'edge "$e" references unknown node "${e.to}"'));
    }
  }

  // Start has no incoming; exit has no outgoing.
  if (start != null && graph.incoming(start.id).isNotEmpty) {
    diags.add(Diagnostic(
        rule: 'start_no_incoming',
        severity: Severity.error,
        nodeId: start.id,
        message: 'start node "${start.id}" must have no incoming edges'));
  }
  for (final t in terminals) {
    if (graph.outgoing(t.id).isNotEmpty) {
      diags.add(Diagnostic(
          rule: 'exit_no_outgoing',
          severity: Severity.error,
          nodeId: t.id,
          message: 'exit node "${t.id}" must have no outgoing edges'));
    }
  }

  // Reachability from start.
  if (start != null) {
    final reachable = _reachableFrom(graph, start.id);
    for (final n in graph.nodes.values) {
      if (!reachable.contains(n.id) && n.id != start.id) {
        diags.add(Diagnostic(
            rule: 'reachability',
            severity: Severity.error,
            nodeId: n.id,
            message: 'node "${n.id}" is unreachable from the start node'));
      }
    }
  }

  // Condition syntax.
  for (final e in graph.edges) {
    if (e.hasCondition && Condition.tryParse(e.condition) == null) {
      diags.add(Diagnostic(
          rule: 'condition_syntax',
          severity: Severity.error,
          message: 'edge "$e" has an unparseable condition: "${e.condition}"'));
    }
  }

  // Unknown shape (no explicit type and shape not in the mapping).
  for (final n in graph.nodes.values) {
    if (n.type.isEmpty && shapeToHandlerType(n.shape) == null) {
      diags.add(Diagnostic(
          rule: 'type_known',
          severity: Severity.warning,
          nodeId: n.id,
          message: 'node "${n.id}" has unknown shape "${n.shape}" '
              '(will use the default codergen handler)'));
    }
  }

  // Retry targets reference real nodes.
  for (final n in graph.nodes.values) {
    if (n.retryTarget.isNotEmpty && !graph.nodes.containsKey(n.retryTarget)) {
      diags.add(Diagnostic(
          rule: 'retry_target_exists',
          severity: Severity.warning,
          nodeId: n.id,
          message: 'node "${n.id}" retry_target "${n.retryTarget}" '
              'does not exist'));
    }
  }

  // Declared context keys reference a node in the graph or an engine seed.
  // A typo'd key silently yields an empty preamble, so warn (a warning keeps
  // the workflow launchable, like retry_target_exists).
  const knownNonNodes = {'input', 'goal', 'graph.goal', 'history'};
  for (final n in graph.nodes.values) {
    for (final key in n.contextKeys) {
      if (graph.nodes.containsKey(key) || knownNonNodes.contains(key)) continue;
      diags.add(Diagnostic(
          rule: 'context_key_unknown',
          severity: Severity.warning,
          nodeId: n.id,
          message: 'node "${n.id}" context key "$key" is not a node in the '
              'graph (and not input/goal/history)'));
    }
  }

  return diags;
}

/// Throw if [validate] produces any error-severity diagnostics.
void validateOrRaise(Graph graph) {
  final errors =
      validate(graph).where((d) => d.severity == Severity.error);
  if (errors.isNotEmpty) {
    throw ArgumentError('invalid pipeline:\n'
        '${errors.map((d) => '  $d').join('\n')}');
  }
}

Set<String> _reachableFrom(Graph graph, String startId) {
  final seen = <String>{};
  final queue = Queue<String>()..add(startId);
  while (queue.isNotEmpty) {
    final id = queue.removeFirst();
    if (!seen.add(id)) continue;
    for (final e in graph.outgoing(id)) {
      if (!seen.contains(e.to)) queue.add(e.to);
    }
  }
  return seen;
}
