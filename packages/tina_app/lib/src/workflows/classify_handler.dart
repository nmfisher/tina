import 'dart:async';

import 'package:attractor/attractor.dart';

/// What one classification stage produced, returned to the [ClassifyHandler]
/// by the composition-injected [ClassifyStageRunner]. The runner owns the
/// mapping from a `ProjectClassificationReport` to [StageStatus] and
/// [contextUpdates] (see docs/proposals/hierarchical_classifiers.md,
/// "Decisions", item 2); the handler only transports it.
class ClassifyStageResult {
  final StageStatus status;

  /// Published into the run context for edge conditions — flat boolean keys
  /// (`label.dart=true`, `coverage.complete=true`, `outcome.classified=true`,
  /// …) so stock `Condition` evaluates programs without a DSL change.
  final Map<String, String> contextUpdates;
  final String notes;
  final String failureReason;

  const ClassifyStageResult({
    required this.status,
    this.contextUpdates = const {},
    this.notes = '',
    this.failureReason = '',
  });
}

/// Runs one named stage of a classifier program. Injected by the composition
/// root (which closes over the workspace, the index options and the progress
/// callbacks of one `/index` invocation); the handler itself stays free of
/// classification imports. Throws to signal infrastructure failure — the
/// engine records it and retries per the node's `max_retries`.
typedef ClassifyStageRunner =
    Future<ClassifyStageResult> Function({
      required String stage,
      Future<void>? cancelSignal,
    });

/// Handler for `type="classify"` program nodes: resolves the stage name
/// (node's `stage` attribute, else the node id), runs it via the injected
/// [runStage], and returns the outcome the engine routes on.
///
/// Cancellation: when the engine's [cancelSignal] has fired, any settled
/// stage — success or failure — maps to `fail("cancelled")`, so a cancelled
/// run's node record says "cancelled" rather than a racy summary. Genuine
/// exceptions propagate so the engine owns retry/recording policy.
class ClassifyHandler implements NodeHandler {
  final ClassifyStageRunner runStage;

  ClassifyHandler(this.runStage);

  /// The stage this node runs: the `stage` attribute when present and
  /// non-blank, else the node id.
  static String stageOf(PipelineNode node) {
    final raw = node.attrs['stage'];
    return raw is String && raw.trim().isNotEmpty ? raw.trim() : node.id;
  }

  @override
  Future<Outcome> execute({
    required PipelineNode node,
    required Graph graph,
    required Context context,
    required RunStore runStore,
    Future<void>? cancelSignal,
    PipelineEventListener? onEvent,
  }) async {
    final stage = stageOf(node);
    var cancelled = false;
    unawaited(cancelSignal?.then((_) => cancelled = true));

    final ClassifyStageResult result;
    try {
      result = await runStage(stage: stage, cancelSignal: cancelSignal);
    } catch (_) {
      if (!cancelled) rethrow;
      final fail = Outcome.fail('cancelled');
      await runStore.writeNode(
        nodeId: node.id,
        outcome: fail,
        prompt: '',
        response: 'cancelled',
      );
      return fail;
    }

    final outcome = cancelled
        ? Outcome.fail('cancelled')
        : Outcome(
            status: result.status,
            contextUpdates: result.contextUpdates,
            notes: result.notes,
            failureReason: result.failureReason,
          );
    await runStore.writeNode(
      nodeId: node.id,
      outcome: outcome,
      prompt: '',
      response: outcome.failureReason.isNotEmpty
          ? outcome.failureReason
          : outcome.notes,
    );
    return outcome;
  }
}
