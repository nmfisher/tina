import 'dart:io';

import 'package:attractor/attractor.dart';
import 'package:path/path.dart' as p;
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';

import '../host/tui_conversation_host.dart';
import '../tui/attention_queue.dart';
import 'file_run_store.dart';
import 'tina_codergen_backend.dart';
import 'tina_interviewer.dart';
import 'workflow_catalog.dart';
import 'workflow_names.dart';

/// The result of one workflow run: the engine's final [outcome] — whose
/// [Outcome.text] carries the last executed node's full response — plus the
/// run-store directory holding the complete audit trail (manifest, per-node
/// prompt/response, checkpoints). `runDir` is empty when no run was started
/// (e.g. the workflow file failed validation).
class PipelineRunResult {
  final Outcome outcome;

  /// Filesystem path of this run's run-store directory.
  final String runDir;

  const PipelineRunResult({required this.outcome, required this.runDir});
}

/// Assembles the attractor engine with tina's two seams (a [TinaCodergenBackend]
/// over the [SubAgentScheduler], and a [TinaInterviewer] over the TUI) and runs
/// a workflow file. One runner per run; constructed by the coordinator (which
/// owns the scheduler, pipeline, host, screen, and editor).
class PipelineRunner {
  final SubAgentScheduler scheduler;
  final AgentPipeline pipeline;

  final Directory workflowsDir;
  final Directory runsRoot;

  /// TUI primitives for human gates. null in headless mode (auto-approve).
  final Screen? screen;
  final LineEditor? editor;

  /// The conversation's resolved `"provider/model"`, inherited by nodes that
  /// omit `llm_model`/`llm_provider`. Threaded to [TinaCodergenBackend].
  final String defaultModelReference;

  /// Builds the per-run permission asker for a run's sink — the TUI supplies
  /// this so a node agent's `write`/`edit` prompt renders in that run's panel.
  /// Null (headless) → asks auto-deny, so workflow writes need `--yolo` /
  /// `--allow` there.
  final PermissionAsker Function(AgentSink runSink)? permissionAskerBuilder;

  /// The TUI's shared modal queue: gates, loop-budget confirms, and
  /// permission asks from ANY run serialize through it, so concurrent runs
  /// can't race on `editor.readKey()`. Null (headless) → each ask runs
  /// directly.
  final AttentionQueue? attentionQueue;

  PipelineRunner({
    required this.scheduler,
    required this.pipeline,
    required this.workflowsDir,
    required this.runsRoot,
    required this.defaultModelReference,
    this.screen,
    this.editor,
    this.permissionAskerBuilder,
    this.attentionQueue,
  });

  /// Run `<workflowsDir>/<workflowName>.dot` to completion. [sink] is where the
  /// turn's streamed text + progress notices go — pass the active host.
  /// [history] (a chat transcript, if any) is seeded into the run context and
  /// expandable as `$history` in node prompts. [onEvent] is an additional
  /// progress listener (e.g. a live run view); the sink notices still fire.
  Future<PipelineRunResult> run({
    required String workflowName,
    required AgentSink sink,
    String? input,
    String? history,
    Future<void>? cancelSignal,
    PipelineEventListener? onEvent,
  }) async {
    final catalog = WorkflowCatalog.standard(workflowsDir: workflowsDir);
    final source = await catalog.read(workflowName);
    final graph = parseDot(source);

    final diags = validate(graph);
    final errors = diags.where((d) => d.severity == Severity.error);
    if (errors.isNotEmpty) {
      final msg = errors.map((d) => '  $d').join('\n');
      sink.notice('workflow "$workflowName" is invalid:\n$msg',
          kind: NoticeKind.error);
      return PipelineRunResult(
          outcome: Outcome.fail('invalid workflow:\n$msg'), runDir: '');
    }
    for (final w in diags.where((d) => d.severity == Severity.warning)) {
      sink.notice('$w', kind: NoticeKind.info);
    }

    // When the run's sink is a TUI conversation host (a live run panel), each
    // node's transcript block opens with its input: a dim node header, then
    // the full task (preamble + prompt) in user style. Headless runs
    // (HeadlessHost) skip this — the `▶ node` notices carry the markers.
    //
    // Node agents prompt per write like the main agent: the run shares ONE
    // mutable policy (a copy of the app policy, so `--yolo`/`--allow` carry
    // in) across every runStandalone call — an "always allow" answered at one
    // node holds for the rest of the run and dies with it. Interactive runs
    // get a real asker; headless runs auto-deny the asks.
    final basePolicy = scheduler.basePolicy;
    final runPolicy = PermissionPolicy(
      defaults: {...?basePolicy?.defaults},
      rules: basePolicy?.staticRules,
    );
    final backend = TinaCodergenBackend(
      scheduler: scheduler,
      sink: sink,
      defaultModelReference: defaultModelReference,
      permissionPolicy: runPolicy,
      permissionAsker: permissionAskerBuilder?.call(sink),
      onNodeStart: sink is TuiConversationHost
          ? (id, task) {
              sink.showMessage('──── node: $id ────',
                  style: HostMessageStyle.dim);
              sink.showMessage(task, style: HostMessageStyle.user);
            }
          : null,
    );
    final interviewer = TinaInterviewer(
      screen: screen,
      editor: editor,
      attentionQueue: attentionQueue,
      sink: sink,
    );

    final runId = _newRunId();
    final runDir = Directory(p.join(runsRoot.path, runId));
    final store = FileRunStore(runDir);

    final codergen = CodergenHandler(backend);
    final registry = NodeHandlerRegistry()
      ..register('start', StartHandler())
      ..register('exit', ExitHandler())
      ..register('conditional', ConditionalHandler())
      ..register('codergen', codergen)
      ..register('wait.human', HumanGateHandler(interviewer));
    // Parallel fan-out (component) + fan-in (tripleoctagon). ParallelHandler
    // resolves branch nodes through this same registry, so register it last.
    registry.register('parallel', ParallelHandler(registry));
    registry.register('parallel.fan_in', ParallelFanInHandler());
    registry.defaultHandler = codergen;

    sink.notice('▶ workflow: $workflowName'
        '${graph.goal.isEmpty ? '' : ' — ${graph.goal}'}');

    final engine = PipelineEngine(
      graph: graph,
      registry: registry,
      runStore: store,
      runId: runId,
      workflowName: workflowName,
      cancelSignal: cancelSignal,
      // Loop budgets pause for a human decision in the TUI; headless runs
      // pass no hook and abort instead of burning budget on a runaway loop.
      onLoopBudgetExceeded: screen != null && editor != null
          ? (reason) async {
              sink.notice('loop budget exhausted: $reason',
                  kind: NoticeKind.warning);
              final answer = await interviewer.ask(Question(
                text: 'Workflow loop budget exhausted: $reason\n'
                    'Continue (budget resets)?',
                type: QuestionType.confirmation,
              ));
              return answer.kind == AnswerValue.yes;
            }
          : null,
      onEvent: (e) {
        _renderEvent(sink, e);
        onEvent?.call(e);
      },
    );

    final outcome = await engine.run(
      input: input,
      seedContext: (history == null || history.isEmpty)
          ? null
          : {'history': history},
    );
    return PipelineRunResult(outcome: outcome, runDir: runDir.path);
  }

  void _renderEvent(AgentSink sink, PipelineEvent e) {
    switch (e.kind) {
      case 'started':
        // already announced above
        break;
      case 'node_started':
        sink.notice('▶ ${e.nodeId}', kind: NoticeKind.info);
        break;
      case 'node_completed':
        sink.notice('✔ ${e.nodeId}', kind: NoticeKind.info);
        break;
      case 'node_retrying':
        sink.notice('↻ ${e.nodeId}: ${e.message}', kind: NoticeKind.warning);
        break;
      case 'node_failed':
        sink.notice('✖ ${e.nodeId}: ${e.message}', kind: NoticeKind.error);
        break;
      case 'completed':
        sink.notice('✔ workflow complete: ${e.message}', kind: NoticeKind.info);
        break;
      case 'failed':
        sink.notice('✖ workflow failed: ${e.message}', kind: NoticeKind.error);
        break;
    }
  }

  /// The names of every `*.dot` file in [dir] (without extension), sorted.
  ///
  /// Thin delegate over [WorkflowCatalog.list] — the catalog owns name
  /// resolution; this keeps the long-standing static entry point for callers
  /// that only have a dir.
  static List<String> listWorkflows(Directory dir) =>
      WorkflowCatalog(workflowsDir: dir).list();

  /// Read `<dir>/<name>.dot`, throwing a clear error if missing — or if the
  /// name could escape the workflows dir (see [isSafeWorkflowName]).
  ///
  /// Thin delegate over [WorkflowCatalog.read] (entry-less catalog: pure
  /// on-disk resolution, so the read seam's semantics are exactly the
  /// historical ones).
  static Future<String> readWorkflow(Directory dir, String name) =>
      WorkflowCatalog(workflowsDir: dir).read(name);
}

String _newRunId() {
  final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  final suffix = DateTime.now().microsecondsSinceEpoch.toRadixString(36).substring(6);
  return '$ts$suffix';
}
