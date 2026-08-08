import 'dart:async';

import '../node_handler.dart';

/// Parallel fan-out (`shape=component`). The node's outgoing edges are split
/// into **branches** (every target that is not a fan-in node) and a single
/// **convergence** — the one target whose handler type is `parallel.fan_in`
/// (a `tripleoctagon` node). Each branch runs against a CLONED copy of the run
/// [Context] so a branch's writes never leak into a sibling; the branches run
/// concurrently ([Future.wait]). The branch outputs are staged under
/// `internal.parallel.<fanout>.branch.<id>` keys (internal, so the preamble
/// skips them) plus a `branches` list, and the outcome routes the engine to
/// the fan-in node via [Outcome.suggestedNextIds].
///
/// The fan-out itself always reaches success: a failed branch is surfaced as
/// text inside the merge so the downstream reviewer can judge it, rather than
/// aborting the whole run.
///
/// Minimal v1 (documented limitations):
/// * Each branch is a SINGLE node — the edge's immediate target. Model a
///   multi-step branch as that executor delegating internally.
/// * One fan-in convergence is supported per fan-out (the first `tripleoctagon`
///   successor); the fan-in reads only its own predecessor's staged branches.
///
/// Branch progress is emitted as engine `node_*` events through [NodeHandler.execute]'s
/// [onEvent] (the engine threads its listener through), so a live view sees
/// each branch start/complete/fail.
class ParallelHandler implements NodeHandler {
  /// Branch nodes are resolved and executed through this registry, so a
  /// `box`/codergen executor runs under the same handler as anywhere else.
  final NodeHandlerRegistry registry;

  ParallelHandler(this.registry);

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
    final branches = <PipelineEdge>[];
    PipelineEdge? convergence;
    for (final e in edges) {
      final target = graph.node(e.to);
      if (target == null) continue;
      if (target.handlerType == 'parallel.fan_in') {
        convergence ??= e; // first fan-in successor wins
      } else {
        branches.add(e);
      }
    }

    if (branches.isEmpty) {
      return _recordFail(runStore, node,
          'parallel fan-out "${node.id}" has no branches');
    }
    if (convergence == null) {
      return _recordFail(runStore, node, 'parallel fan-out "${node.id}" has no '
          'fan-in (tripleoctagon) successor to merge into');
    }

    // Run every branch against its own cloned context, concurrently.
    final results = await Future.wait(branches.map((e) => _runBranch(
          edge: e,
          graph: graph,
          baseContext: context,
          runStore: runStore,
          cancelSignal: cancelSignal,
          onEvent: onEvent,
        )));

    // Stage each branch's output under an internal, fan-out-namespaced key so
    // the preamble skips it; record the ordered branch list for the fan-in.
    final updates = <String, String>{};
    final branchIds = <String>[];
    var failures = 0;
    for (final r in results) {
      // A failed codergen branch still records its node id with an EMPTY
      // string, so treat an empty output as "no output" and surface the
      // failure reason instead.
      final raw = r.outcome.contextUpdates[r.nodeId] ?? '';
      final out = raw.isNotEmpty
          ? raw
          : (r.outcome.status == StageStatus.fail
              ? '(branch "${r.nodeId}" failed: ${r.outcome.failureReason})'
              : '(branch "${r.nodeId}" produced no output)');
      if (r.outcome.status == StageStatus.fail) failures++;
      updates['internal.parallel.${node.id}.branch.${r.nodeId}'] = out;
      branchIds.add(r.nodeId);
    }
    updates['internal.parallel.${node.id}.branches'] = branchIds.join(',');
    updates['last_stage'] = node.id;
    updates['last_response'] = 'fanned out to ${branches.length} branch(es)'
        '${failures == 0 ? '' : ' ($failures failed)'}';

    final outcome = Outcome.success(
      suggestedNextIds: [convergence.to],
      contextUpdates: updates,
      notes: 'fanned out to ${branches.length} branch(es) '
          '(${failures == 0 ? 'all ok' : '$failures failed'}); '
          'merging at "${convergence.to}"',
    );
    await runStore.writeNode(
        nodeId: node.id,
        outcome: outcome,
        prompt: 'fan-out to ${branches.length} branches',
        response: '');
    return outcome;
  }

  Future<_BranchResult> _runBranch({
    required PipelineEdge edge,
    required Graph graph,
    required Context baseContext,
    required RunStore runStore,
    Future<void>? cancelSignal,
    PipelineEventListener? onEvent,
  }) async {
    final branchNode = graph.node(edge.to)!;
    final branchCtx = baseContext.clone();
    // Branches bypass the engine's _executeWithRetry emit sites, so the
    // handler emits their lifecycle itself (a single attempt — no retries).
    onEvent?.call(PipelineEvent('node_started', nodeId: branchNode.id));
    try {
      final outcome = await registry.resolve(branchNode).execute(
            node: branchNode,
            graph: graph,
            context: branchCtx,
            runStore: runStore,
            cancelSignal: cancelSignal,
            onEvent: onEvent,
          );
      if (outcome.status.isOk) {
        onEvent?.call(PipelineEvent('node_completed',
            nodeId: branchNode.id, outcome: outcome));
      } else {
        onEvent?.call(PipelineEvent('node_failed',
            nodeId: branchNode.id,
            outcome: outcome,
            message: outcome.failureReason));
      }
      return _BranchResult(branchNode.id, outcome);
    } catch (e) {
      // One bad branch must not take down the fan-out; surface it as a failed
      // branch and let the merge/reviewer handle it.
      final fail = Outcome.fail('branch error: $e');
      onEvent?.call(PipelineEvent('node_failed',
          nodeId: branchNode.id, outcome: fail, message: fail.failureReason));
      return _BranchResult(branchNode.id, fail);
    }
  }
}

class _BranchResult {
  final String nodeId;
  final Outcome outcome;
  const _BranchResult(this.nodeId, this.outcome);
}

/// Parallel fan-in (`shape=tripleoctagon`). Merges the branch outputs its
/// fan-out predecessor staged — under `internal.parallel.<fanout>.branch.<id>`
/// — into a single consolidated result under this node's id, so the next
/// node's preamble sees one "execution results" block instead of N internal
/// keys. The predecessor is the incoming edge whose source resolves to a
/// `parallel` handler. A no-op success when there is no such predecessor or no
/// staged branches.
class ParallelFanInHandler implements NodeHandler {
  @override
  Future<Outcome> execute({
    required PipelineNode node,
    required Graph graph,
    required Context context,
    required RunStore runStore,
    Future<void>? cancelSignal,
    PipelineEventListener? onEvent,
  }) async {
    final fanoutId = _fanOutPredecessor(node, graph);
    final outputs = <String, String>{};
    if (fanoutId != null) {
      final list =
          context.getString('internal.parallel.$fanoutId.branches');
      for (final id in list.split(',')) {
        if (id.isEmpty) continue;
        outputs[id] =
            context.getString('internal.parallel.$fanoutId.branch.$id');
      }
    }

    if (outputs.isEmpty) {
      final outcome = Outcome.success(
        contextUpdates: {node.id: '(no branches merged)'},
        notes: 'fan-in "${node.id}": no branches to merge',
      );
      await runStore.writeNode(
          nodeId: node.id, outcome: outcome, prompt: '', response: '');
      return outcome;
    }

    final buf = StringBuffer();
    for (final entry in outputs.entries) {
      buf.writeln('--- ${entry.key} ---');
      buf.writeln(entry.value);
      buf.writeln();
    }
    final merged = buf.toString().trimRight();
    final outcome = Outcome.success(
      contextUpdates: {
        node.id: merged,
        'last_stage': node.id,
        'last_response': _truncate(merged, 200),
      },
      notes: 'merged ${outputs.length} branch(es) at "${node.id}"',
    );
    await runStore.writeNode(
        nodeId: node.id, outcome: outcome, prompt: '', response: merged);
    return outcome;
  }

  /// The id of this fan-in node's fan-out predecessor — the incoming edge
  /// whose source resolves to a `parallel` handler — if any.
  String? _fanOutPredecessor(PipelineNode node, Graph graph) {
    for (final e in graph.incoming(node.id)) {
      final src = graph.node(e.from);
      if (src != null && src.handlerType == 'parallel') return src.id;
    }
    return null;
  }
}

Future<Outcome> _recordFail(RunStore runStore, PipelineNode node, String reason) async {
  // Errors are recorded before returning so the audit trail still has an entry
  // for the fan-out node; the engine wraps this in its retry/event handling.
  final outcome = Outcome.fail(reason);
  await runStore.writeNode(
      nodeId: node.id, outcome: outcome, prompt: '', response: '');
  return outcome;
}

String _truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}…';
