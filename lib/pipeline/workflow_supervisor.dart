import 'dart:async';

import 'package:attractor/attractor.dart';
import 'package:tina_engine/tina_engine.dart';

import 'pipeline_runner.dart';

/// Runs one workflow as a child run. This is the seam the supervisor calls; in
/// production it is `PipelineRunner.run`, so the supervisor reuses the runner,
/// the engine, and every handler without owning them. The [sink] is where the
/// run's streamed text + node progress events land (by default the launching
/// chat's host; the coordinator swaps in a live panel host for the run via the
/// supervisor's `onLaunch` hook — see [WorkflowRun.sink]); the [cancelSignal]
/// future, when completed, aborts the run with a `cancelled` outcome — exactly
/// the engine's existing contract.
typedef RunWorkflow = Future<PipelineRunResult> Function({
  required String workflowName,
  required AgentSink sink,
  String? input,
  String? history,
  Future<void>? cancelSignal,
  PipelineEventListener? onEvent,
});

/// Where a [WorkflowRun] is in its lifecycle.
enum WorkflowRunStatus {
  /// The child run is in flight.
  running,

  /// The run finished successfully.
  completed,

  /// The run finished in failure (a node failed, a goal gate was unsatisfied).
  failed,

  /// The run was stopped ([WorkflowSupervisor.stop]) and aborted.
  cancelled,
}

/// A background workflow run owned by a [WorkflowSupervisor]. The handle the
/// main agent gets back from a launch: it carries the run's identity, its
/// lifecycle [status], and — once finished — the final [Outcome]. The cancel
/// completer is private so only the supervisor can abort the run.
class WorkflowRun {
  final String id;
  final String workflowName;

  /// The id of the conversation that launched the run. Used to route the
  /// completion turn (the supervisor's `onComplete` hook) back to the chat
  /// that asked for the workflow.
  final String conversationId;

  /// The optional per-launch annotation of the run's purpose, surfaced in the
  /// launch/report notices. Does NOT override the graph's own `goal`.
  final String? goal;

  /// The task text that flowed into the run as `$input` (if any).
  final String? input;

  /// Per-node live status, maintained by the supervisor's internal listener
  /// from the engine's `node_*` events. Never misses an event (the internal
  /// listener is wired before the runner starts), so a run panel can render
  /// final state from this even if its external listener joined late.
  final Map<String, NodeRunStatus> nodeStatus = {};

  /// The run's stream sink — where node text + progress events land. By
  /// default the launching chat's host (the sink passed to [launch]); the host
  /// installs a per-run panel host here inside the supervisor's `onLaunch`
  /// hook, before the runner starts, so the run's transcript renders in a live
  /// panel instead of the chat.
  AgentSink? sink;

  /// External progress listener, set by the host (typically inside the
  /// supervisor's `onLaunch` hook, before any production event can arrive).
  /// Receives every engine event after the internal [nodeStatus] update.
  PipelineEventListener? onEvent;

  /// Fired after the run finishes (both success and error paths), after
  /// `onComplete` — the host uses it to settle the run panel's busy state.
  void Function()? onFinished;

  /// The run-store directory for this run (manifest, per-node prompt/response,
  /// checkpoints), set from the runner's result once the run finishes. null
  /// until then, or when no run was started (invalid workflow file).
  String? runDir;

  final Completer<void> _cancel;

  WorkflowRunStatus status;
  Outcome? outcome;

  WorkflowRun({
    required this.id,
    required this.workflowName,
    required this.conversationId,
    required this.goal,
    required this.input,
    required Completer<void> cancel,
  })  : _cancel = cancel,
        status = WorkflowRunStatus.running;

  /// Whether the run is still in flight.
  bool get isRunning => status == WorkflowRunStatus.running;

  void _signalCancel() {
    if (!_cancel.isCompleted) _cancel.complete();
  }
}

/// The manager loop: a supervisor that **observes, steers, and waits** over
/// child workflow runs (the attractor `house` / `stack.manager_loop` pattern).
///
/// The main agent (the chat conversation) is the persistent top-level context.
/// Normal turns run the plain agent; a workflow is launched on demand as a
/// **background child run** via the agent's `launch_workflow` tool. The
/// supervisor does five things:
///
/// 1. **Launch** ([launch]) — start a workflow as a fire-and-forget run,
///    returning immediately with a [WorkflowRun] handle. The host installs a
///    per-run stream sink on the run inside `onLaunch` (a live panel host, so
///    node text + progress render in a panel instead of the chat).
/// 2. **Monitor** — the run's events (`node_started`, `node_completed`, …) reach
///    the sink that was installed; nothing extra is needed.
/// 3. **Stop** ([stop]/[stopAll]) — complete a run's cancel signal so the engine
///    aborts the current node with a `cancelled` outcome.
/// 4. **Report back** — when the run finishes (success, failure, or cancel) the
///    supervisor posts one final notice to the sink.
/// 5. **Hand off** — the `onComplete` hook fires after the report notice; the
///    coordinator wires it to the conversation controller, which wakes the
///    launching agent with a synthetic turn carrying the outcome.
///
/// Because [launch] is fire-and-forget, the main agent's turn never blocks: the
/// user can keep chatting while the run churns.
class WorkflowSupervisor {
  final RunWorkflow _run;

  /// Fired after a run finishes and its report notice has been posted. The
  /// coordinator wires this to the controller's completion-turn injection.
  final void Function(WorkflowRun run)? onComplete;

  /// Fired synchronously inside [launch], after the launch notice is posted
  /// and before any engine event can be delivered — the host opens the run's
  /// live view here and attaches [WorkflowRun.onEvent].
  final void Function(WorkflowRun run)? onLaunch;

  /// Active + recently-finished runs keyed by id (newest last). Finished runs
  /// are kept so the main agent can query a result by id; [active] filters to
  /// the still-running ones.
  final Map<String, WorkflowRun> _runs = {};
  final List<String> _launchOrder = [];
  int _seq = 0;

  WorkflowSupervisor({required RunWorkflow run, this.onComplete, this.onLaunch})
      : _run = run;

  /// Launch `<name>` as a background child run for the conversation
  /// [conversationId]. [sink] is where the supervisor's own notices (launch +
  /// completion report) go — the launching chat's host. The run's streamed
  /// text + node progress land on [sink] too unless the host installs a
  /// per-run panel sink on the run inside `onLaunch` (see [WorkflowRun.sink]).
  /// [input] flows into the run as `$input`; [goal] annotates the run for the
  /// launch/report notices. Returns immediately with a handle; the run
  /// continues after this returns. (The run's `history` is always `null` —
  /// the launching agent crafts [input]; the runner's `history` arg is unused.)
  ///
  /// [onEvent] is the run's external progress listener; the host typically
  /// passes it through the constructor's [onLaunch] hook instead (which fires
  /// after the launch notice, before any engine event can be delivered).
  WorkflowRun launch({
    required String name,
    required String conversationId,
    required AgentSink sink,
    String? input,
    String? goal,
    PipelineEventListener? onEvent,
  }) {
    final id = _newId();
    final cancel = Completer<void>();
    final run = WorkflowRun(
      id: id,
      workflowName: name,
      conversationId: conversationId,
      goal: goal,
      input: input,
      cancel: cancel,
    );
    // The internal listener (nodeStatus tracking) is wired BEFORE the runner
    // starts, so even a synchronously-emitting runner records every event.
    run.onEvent = onEvent;
    _runs[id] = run;
    _launchOrder.add(id);

    sink.notice('▶ workflow launched: $name [run $id]'
        '${goal == null || goal.isEmpty ? '' : ' — $goal'}');

    // Fire-and-forget: report back on completion without blocking launch.
    // onLaunch fires synchronously BEFORE the runner starts — the host opens
    // the run's live view here, installs the run's stream sink
    // ([WorkflowRun.sink], a panel host), and attaches listeners. Nothing can
    // be missed: `_run` is invoked after the hook returns, and its first await
    // (reading the workflow file) gates the engine's first emission.
    onLaunch?.call(run);

    final future = _run(
      workflowName: name,
      // The run's stream lands on the panel host when onLaunch installed one;
      // otherwise it falls back to the launching chat's sink.
      sink: run.sink ?? sink,
      input: input,
      history: null,
      cancelSignal: cancel.future,
      onEvent: (e) {
        _applyNodeStatus(run, e);
        run.onEvent?.call(e);
      },
    );
    unawaited(future.then(
      (result) {
        run.outcome = result.outcome;
        if (result.runDir.isNotEmpty) run.runDir = result.runDir;
        run.status =
            _classify(result.outcome, cancelledByStop: cancel.isCompleted);
        _reportBack(sink, run);
        onComplete?.call(run);
        run.onFinished?.call();
      },
      // A thrown runner error (e.g. the workflow file is missing) never yields
      // a result — surface it as a failed run so the launch still reports
      // back and the completion turn still fires, instead of an unhandled
      // async error.
      onError: (Object e) {
        run.outcome = Outcome.fail('$e');
        run.status = WorkflowRunStatus.failed;
        _reportBack(sink, run);
        onComplete?.call(run);
        run.onFinished?.call();
      },
    ));

    return run;
  }

  /// Update [run]'s per-node status map from an engine event. Node events
  /// without a nodeId (`started`, `completed`, `failed`) are ignored.
  void _applyNodeStatus(WorkflowRun run, PipelineEvent e) {
    final id = e.nodeId;
    if (id == null) return;
    switch (e.kind) {
      case 'node_started':
      case 'node_retrying':
        run.nodeStatus[id] = NodeRunStatus.running;
      case 'node_completed':
        run.nodeStatus[id] = e.outcome?.status == StageStatus.skipped
            ? NodeRunStatus.skipped
            : NodeRunStatus.done;
      case 'node_failed':
        run.nodeStatus[id] = NodeRunStatus.failed;
      default:
        break;
    }
  }

  /// Stop the run [id] (or the most recent still-running launch when null).
  /// Returns true when a running run was signalled to stop.
  bool stop([String? id]) {
    final target = id == null ? _mostRecentActive() : _runs[id];
    if (target == null || !target.isRunning) return false;
    target._signalCancel();
    return true;
  }

  /// Stop every still-running launch.
  void stopAll() {
    for (final run in _runs.values) {
      if (run.isRunning) run._signalCancel();
    }
  }

  /// Still-running launches, newest first.
  List<WorkflowRun> get active =>
      _launchOrder.reversed.map((id) => _runs[id]).whereType<WorkflowRun>().where((r) => r.isRunning).toList();

  /// Look up a run by id (active or finished).
  WorkflowRun? find(String id) => _runs[id];

  WorkflowRun? _mostRecentActive() {
    for (final id in _launchOrder.reversed) {
      final run = _runs[id];
      if (run != null && run.isRunning) return run;
    }
    return null;
  }

  WorkflowRunStatus _classify(Outcome outcome,
      {required bool cancelledByStop}) {
    if (cancelledByStop) return WorkflowRunStatus.cancelled;
    if (outcome.failureReason == 'cancelled') return WorkflowRunStatus.cancelled;
    return outcome.status.isOk
        ? WorkflowRunStatus.completed
        : WorkflowRunStatus.failed;
  }

  void _reportBack(AgentSink sink, WorkflowRun run) {
    switch (run.status) {
      case WorkflowRunStatus.completed:
        sink.notice('✔ workflow complete: ${run.workflowName} [run ${run.id}]',
            kind: NoticeKind.info);
      case WorkflowRunStatus.cancelled:
        sink.notice('✖ workflow cancelled: ${run.workflowName} [run ${run.id}]',
            kind: NoticeKind.warning);
      case WorkflowRunStatus.failed:
        final reason = run.outcome?.failureReason.isNotEmpty == true
            ? run.outcome!.failureReason
            : 'failed';
        sink.notice(
            '✖ workflow failed: ${run.workflowName} [run ${run.id}]: $reason',
            kind: NoticeKind.error);
      case WorkflowRunStatus.running:
        break; // unreachable: report only fires on completion.
    }
  }

  String _newId() {
    // Monotonic, deterministic, short. (DateTime is avoided so the class stays
    // cheap to reason about in tests; uniqueness comes from the _seq counter.)
    _seq += 1;
    return _seq.toRadixString(36);
  }
}
