import 'dart:async';

import 'condition.dart';
import 'node_handler.dart';

/// The traversal engine. Holds no run state between [run] calls; each run is
/// independent. The host constructs one engine per run.
class PipelineEngine {
  final Graph graph;
  final NodeHandlerRegistry registry;
  final RunStore runStore;
  final String runId;
  final String workflowName;

  /// Optional progress listener (node start/stop, completion).
  final PipelineEventListener? onEvent;

  /// Backoff between retries: `attempt` is 1-indexed (the first retry). The
  /// default is capped exponential; tests pass `(_) => Duration.zero`.
  final Duration Function(int attempt) backoffFor;

  /// Aborts the run: completing this future makes the next handler call throw
  /// an [Aborted] (caught and turned into a fail outcome).
  final Future<void>? cancelSignal;

  /// Consulted when a loop budget is exhausted (node visit cap, total-step
  /// cap, or goal-gate retry-jump cap). Return true to continue the run with
  /// that budget reset, false (or throw, or leave null) to abort with the
  /// reason. Interactive hosts wire this to a human yes/no; a null hook
  /// (headless) always aborts.
  final Future<bool> Function(String reason)? onLoopBudgetExceeded;

  PipelineEngine({
    required this.graph,
    required this.registry,
    required this.runStore,
    required this.runId,
    required this.workflowName,
    this.onEvent,
    this.backoffFor = _defaultBackoff,
    this.cancelSignal,
    this.onLoopBudgetExceeded,
  });

  /// Run the pipeline to completion (or failure). [input] is recorded in the
  /// manifest and available as `context.input`; [seedContext] values are
  /// pre-seeded into the run context (e.g. `history` for a chat turn) and are
  /// expandable in prompts as `$<key>`.
  Future<Outcome> run(
      {String? input, Map<String, String>? seedContext}) async {
    final context = Context();
    context.set('graph.goal', graph.goal);
    if (input != null && input.isNotEmpty) context.set('input', input);
    if (seedContext != null) {
      for (final e in seedContext.entries) {
        context.set(e.key, e.value);
      }
    }

    await runStore.init(
      runId: runId,
      workflowName: workflowName,
      goal: graph.goal,
      input: input,
    );
    onEvent?.call(PipelineEvent('started', message: workflowName));

    final nodeOutcomes = <String, Outcome>{};
    final completed = <String>[];
    final retries = <String, int>{};

    // A Future exposes no synchronous completion test; flip a flag the moment
    // the cancel signal resolves. The loop only checks between awaits, so the
    // flag is always up to date by then.
    var cancelled = false;
    bool isCancelled() => cancelled;
    unawaited(cancelSignal?.then((_) => cancelled = true));

    // Loop budgets: per-node visits, total steps, and goal-gate retry jumps.
    // Each guards against runaway LLM spend from a cyclic graph; exceeding one
    // consults [onLoopBudgetExceeded] before aborting.
    final maxNodeVisits = _intGraphAttr('max_node_visits', 8);
    final maxSteps = _intGraphAttr('max_steps', 200);
    final visits = <String, int>{};
    final gateJumps = <String, int>{};
    var steps = 0;

    var start = graph.findStartNode();
    if (start == null) {
      return _finish(Outcome.fail('no start node'), context, completed);
    }

    PipelineNode current = start;
    while (true) {
      // Cancellation terminates the traversal: the run ends at the current
      // node instead of walking the rest of the graph marking nodes failed.
      if (isCancelled()) {
        return _finish(Outcome.fail('cancelled'), context, completed);
      }
      context.set('current_node', current.id);

      // Total-step cap over the whole run.
      steps++;
      if (steps > maxSteps) {
        final reason =
            'run exceeded $maxSteps total steps (possible runaway loop)';
        if (await _continuePastBudget(reason)) {
          steps = 0;
        } else {
          return _finish(Outcome.fail(reason), context, completed);
        }
      }

      // Per-node visit cap — catches revise/clarify self-loops.
      if ((visits[current.id] ?? 0) + 1 > maxNodeVisits) {
        final reason = '"${current.id}" exceeded $maxNodeVisits visits '
            '(possible loop)';
        if (await _continuePastBudget(reason)) {
          visits[current.id] = 0;
        } else {
          return _finish(Outcome.fail(reason), context, completed);
        }
      }
      visits[current.id] = (visits[current.id] ?? 0) + 1;

      // Terminal node — enforce goal gates before exiting.
      if (graph.isTerminal(current)) {
        final failedGate = _unsatisfiedGoalGate(nodeOutcomes);
        if (failedGate != null) {
          // Bound the number of retry jumps an unsatisfied gate can force —
          // a stale nodeOutcomes entry otherwise loops the terminal jump
          // forever. Budget: the node's own max_retries, else the graph's
          // default, else 2 (always at least 1).
          final budget = _gateJumpBudget(failedGate);
          final jumps = (gateJumps[failedGate.id] ?? 0) + 1;
          if (jumps > budget) {
            final reason = 'goal gate "${failedGate.id}" retry budget '
                'exhausted ($budget jump${budget == 1 ? '' : 's'} without '
                'satisfying the gate)';
            if (await _continuePastBudget(reason)) {
              gateJumps[failedGate.id] = 0;
            } else {
              return _finish(Outcome.fail(reason), context, completed);
            }
          }
          gateJumps[failedGate.id] = jumps;
          final target = _retryTargetFor(failedGate) ??
              _graphRetryTarget();
          if (target != null && graph.node(target) != null) {
            current = graph.node(target)!;
            continue;
          }
          return _finish(
            Outcome.fail('goal gate "${failedGate.id}" unsatisfied '
                'and no retry target'),
            context,
            completed,
          );
        }
        return _finish(
          const Outcome.success(notes: 'pipeline completed'),
          context,
          completed,
        );
      }

      // Execute with retry.
      final outcome = await _executeWithRetry(
        current,
        context,
        retries,
        isCancelled,
      );

      completed.add(current.id);
      nodeOutcomes[current.id] = outcome;
      context.applyUpdates(outcome.contextUpdates);
      context.set('outcome', outcome.status.wire);
      if (outcome.preferredLabel != null &&
          outcome.preferredLabel!.isNotEmpty) {
        context.set('preferred_label', outcome.preferredLabel!);
      }

      await runStore.writeCheckpoint(
        currentNode: current.id,
        completedNodes: completed,
        context: context,
      );

      final next = _selectEdge(current, outcome, context);
      if (next == null) {
        if (outcome.status == StageStatus.fail) {
          return _finish(outcome, context, completed);
        }
        return _finish(
          const Outcome.success(notes: 'pipeline completed'),
          context,
          completed,
        );
      }
      current = graph.node(next.to)!;
    }
  }

  // -- Retry wrapper --------------------------------------------------------

  Future<Outcome> _executeWithRetry(
    PipelineNode node,
    Context context,
    Map<String, int> retries,
    bool Function() isCancelled,
  ) async {
    final handler = registry.resolve(node);
    final maxAttempts = (node.maxRetries ?? graph.defaultMaxRetries) + 1;

    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      onEvent?.call(PipelineEvent('node_started', nodeId: node.id));

      final Outcome outcome;
      try {
        outcome = await handler.execute(
          node: node,
          graph: graph,
          context: context,
          runStore: runStore,
          cancelSignal: cancelSignal,
          onEvent: onEvent,
        );
      } on Aborted {
        return Outcome.fail('cancelled');
      } catch (e) {
        // Handler threw — fail this attempt.
        final fail = Outcome.fail('handler error in "${node.id}": $e');
        onEvent?.call(PipelineEvent('node_failed',
            nodeId: node.id, outcome: fail, message: fail.failureReason));
        if (attempt < maxAttempts) {
          if (isCancelled()) return Outcome.fail('cancelled');
          await Future.delayed(backoffFor(attempt));
          continue;
        }
        return fail;
      }

      if (outcome.status.isOk) {
        retries.remove(node.id);
        onEvent?.call(
            PipelineEvent('node_completed', nodeId: node.id, outcome: outcome));
        return outcome;
      }
      if (outcome.status == StageStatus.retry) {
        onEvent?.call(PipelineEvent('node_retrying',
            nodeId: node.id,
            outcome: outcome,
            message: outcome.failureReason));
        if (attempt < maxAttempts) {
          if (isCancelled()) return Outcome.fail('cancelled');
          retries[node.id] = (retries[node.id] ?? 0) + 1;
          await Future.delayed(backoffFor(attempt));
          continue;
        }
        if (node.allowPartial) {
          return outcome.copyWith(status: StageStatus.partialSuccess);
        }
        final exhausted =
            outcome.copyWith(status: StageStatus.fail);
        onEvent?.call(PipelineEvent('node_failed',
            nodeId: node.id, outcome: exhausted, message: 'max retries exceeded'));
        return exhausted;
      }
      if (outcome.status == StageStatus.fail) {
        onEvent?.call(PipelineEvent('node_failed',
            nodeId: node.id, outcome: outcome, message: outcome.failureReason));
        return outcome;
      }
      // skipped — return as-is.
      onEvent?.call(
          PipelineEvent('node_completed', nodeId: node.id, outcome: outcome));
      return outcome;
    }
    return Outcome.fail('max retries exceeded for "${node.id}"');
  }

  // -- Edge selection (spec §3.3) ------------------------------------------

  PipelineEdge? _selectEdge(
      PipelineNode node, Outcome outcome, Context context) {
    final edges = graph.outgoing(node.id);
    if (edges.isEmpty) return null;

    // Step 1: condition-matching edges.
    final matched = <PipelineEdge>[];
    for (final e in edges) {
      if (!e.hasCondition) continue;
      final cond = Condition.tryParse(e.condition);
      if (cond != null && cond.evaluate(outcome, context)) {
        matched.add(e);
      }
    }
    if (matched.isNotEmpty) return _bestByWeightThenLexical(matched);

    final unconditional = edges.where((e) => !e.hasCondition).toList();

    // Step 2: preferred label.
    if (outcome.preferredLabel != null && outcome.preferredLabel!.isNotEmpty) {
      final want = _normalizeLabel(outcome.preferredLabel!);
      for (final e in unconditional) {
        if (_normalizeLabel(e.label) == want) return e;
      }
    }

    // Step 3: suggested next ids.
    if (outcome.suggestedNextIds.isNotEmpty) {
      for (final id in outcome.suggestedNextIds) {
        for (final e in unconditional) {
          if (e.to == id) return e;
        }
      }
    }

    // Steps 4 & 5: weight then lexical among unconditional edges.
    if (unconditional.isNotEmpty) return _bestByWeightThenLexical(unconditional);

    // Fallback: any edge (e.g. all are conditional but none matched).
    return _bestByWeightThenLexical(edges);
  }

  PipelineEdge _bestByWeightThenLexical(List<PipelineEdge> edges) {
    final sorted = [...edges]
      ..sort((a, b) {
        final byWeight = b.weight.compareTo(a.weight);
        if (byWeight != 0) return byWeight;
        return a.to.compareTo(b.to);
      });
    return sorted.first;
  }

  String? _normalizeLabel(String label) {
    var s = label.trim().toLowerCase();
    s = s.replaceAll(RegExp(r'^\[[A-Za-z0-9]\]\s*'), '');
    s = s.replaceAll(RegExp(r'^[A-Za-z0-9][)\\-—]\s*'), '');
    return s;
  }

  // -- Loop budgets -----------------------------------------------------------

  /// Ask the host whether to continue past an exhausted budget. No hook
  /// (headless) or a false answer aborts the run.
  Future<bool> _continuePastBudget(String reason) async {
    final hook = onLoopBudgetExceeded;
    if (hook == null) return false;
    return await hook(reason);
  }

  int _intGraphAttr(String key, int fallback) {
    final v = graph.attrs[key];
    if (v is int) return v;
    if (v is String) return int.tryParse(v) ?? fallback;
    return fallback;
  }

  int _gateJumpBudget(PipelineNode gate) {
    final budget = gate.maxRetries ?? graph.defaultMaxRetries;
    if (budget >= 1) return budget;
    return 2;
  }

  // -- Goal gates (spec §3.4) ----------------------------------------------

  PipelineNode? _unsatisfiedGoalGate(Map<String, Outcome> nodeOutcomes) {
    for (final entry in nodeOutcomes.entries) {
      final node = graph.node(entry.key);
      if (node != null && node.goalGate && !entry.value.status.isOk) {
        return node;
      }
    }
    return null;
  }

  String? _retryTargetFor(PipelineNode node) {
    if (node.retryTarget.isNotEmpty) return node.retryTarget;
    final fallback = node.attrs['fallback_retry_target'];
    return fallback is String && fallback.isNotEmpty ? fallback : null;
  }

  String? _graphRetryTarget() {
    final primary = graph.attrs['retry_target'];
    if (primary is String && primary.isNotEmpty) return primary;
    final fallback = graph.attrs['fallback_retry_target'];
    return fallback is String && fallback.isNotEmpty ? fallback : null;
  }

  // -- Finalize -------------------------------------------------------------

  Future<Outcome> _finish(
      Outcome outcome, Context context, List<String> completed) async {
    await runStore.writeCheckpoint(
      currentNode: outcome.status.isOk ? (completed.isNotEmpty ? completed.last : '') : (completed.isNotEmpty ? completed.last : ''),
      completedNodes: completed,
      context: context,
    );
    await runStore.finalize(status: outcome.status, failureReason: outcome.failureReason.isEmpty ? null : outcome.failureReason);
    onEvent?.call(PipelineEvent(
      outcome.status.isOk ? 'completed' : 'failed',
      outcome: outcome,
      message: outcome.status.isOk ? outcome.notes : outcome.failureReason,
    ));
    return outcome;
  }
}

/// Raised internally when [PipelineEngine.cancelSignal] fires mid-handler.
class Aborted implements Exception {
  const Aborted();
}

Duration _defaultBackoff(int attempt) {
  final ms = (200 * (1 << (attempt - 1))).clamp(200, 60000);
  return Duration(milliseconds: ms);
}
