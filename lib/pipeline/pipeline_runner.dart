import 'dart:io';

import 'package:attractor/attractor.dart';
import 'package:path/path.dart' as p;
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';

import 'file_run_store.dart';
import 'tina_codergen_backend.dart';
import 'tina_interviewer.dart';

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

  PipelineRunner({
    required this.scheduler,
    required this.pipeline,
    required this.workflowsDir,
    required this.runsRoot,
    required this.defaultModelReference,
    this.screen,
    this.editor,
  });

  /// Run `<workflowsDir>/<workflowName>.dot` to completion. [sink] is where the
  /// turn's streamed text + progress notices go — pass the active host.
  /// [history] (a chat transcript, if any) is seeded into the run context and
  /// expandable as `$history` in node prompts. [onEvent] is an additional
  /// progress listener (e.g. a live run view); the sink notices still fire.
  Future<Outcome> run({
    required String workflowName,
    required AgentSink sink,
    String? input,
    String? history,
    Future<void>? cancelSignal,
    PipelineEventListener? onEvent,
  }) async {
    final source = await readWorkflow(workflowsDir, workflowName);
    final graph = parseDot(source);

    final diags = validate(graph);
    final errors = diags.where((d) => d.severity == Severity.error);
    if (errors.isNotEmpty) {
      final msg = errors.map((d) => '  $d').join('\n');
      sink.notice('workflow "$workflowName" is invalid:\n$msg',
          kind: NoticeKind.error);
      return Outcome.fail('invalid workflow:\n$msg');
    }
    for (final w in diags.where((d) => d.severity == Severity.warning)) {
      sink.notice('$w', kind: NoticeKind.info);
    }

    final backend = TinaCodergenBackend(
        scheduler: scheduler,
        sink: sink,
        defaultModelReference: defaultModelReference);
    final interviewer = TinaInterviewer(screen: screen, editor: editor);

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
      onEvent: (e) {
        _renderEvent(sink, e);
        onEvent?.call(e);
      },
    );

    return engine.run(
      input: input,
      seedContext: (history == null || history.isEmpty)
          ? null
          : {'history': history},
    );
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
  static List<String> listWorkflows(Directory dir) {
    if (!dir.existsSync()) return const [];
    return dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.dot'))
        .map((f) => p.basenameWithoutExtension(f.path))
        .toList()
      ..sort();
  }

  /// Read `<dir>/<name>.dot`, throwing a clear error if missing.
  static Future<String> readWorkflow(Directory dir, String name) async {
    final file = File(p.join(dir.path, '$name.dot'));
    if (!await file.exists()) {
      throw FileSystemException('workflow not found', file.path);
    }
    return file.readAsString();
  }
}

String _newRunId() {
  final ts = DateTime.now().millisecondsSinceEpoch.toRadixString(36);
  final suffix = DateTime.now().microsecondsSinceEpoch.toRadixString(36).substring(6);
  return '$ts$suffix';
}
