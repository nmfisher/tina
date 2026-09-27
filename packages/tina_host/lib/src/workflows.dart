/// Workflows: a named graph of steps, run to completion through the
/// session's own loop — one real [AgentLoop.runTurn] per LLM node, not
/// a side channel. The graph format is Graphviz DOT, parsed, validated
/// and traversed by the `attractor` package (the same engine the old
/// app used); what changed is the seam. The old app ran nodes through a
/// background scheduler with its own run-store directory and its own
/// permission surface; here a node's agent turn **is** a session turn —
/// it streams like any turn, its messages live in the log, and it
/// survives a resume like any turn. That is the brief's "running them
/// through the existing loop", literally.
///
/// Ported from the old app's `workflows/` (~2,203 lines), reduced to
/// the smallest useful version:
///
/// - **definition** — a `.dot` file under `<tinaDir>/workflows/`. The
///   catalog is the old `WorkflowCatalog` ported with its pinned
///   semantics (files shadow entries; `list` is the on-disk scan only;
///   the default name is file-based only), plus the old name-hygiene
///   guard, so `../evil` can never escape the workflows dir. The seed
///   graph is the old default workflow with the parallel fan-out
///   reduced to one executor — parallel is deliberately not ported.
/// - **running** — `/workflow run <name> [input]` walks the graph
///   inline: each `box`/LLM node becomes one turn whose input is the
///   node's expanded prompt (prior-node outputs via its `context`
///   attribute, `$goal`/`$input` expansion), each `hexagon` human gate
///   is asked on the session's [Terminal], and a reviewer's trailing
///   `VERDICT: <label>` line routes the next edge the way the old
///   autonomous reviewers did.
/// - **outcome** — one [WorkflowRunEntry] through `recordState`, so the
///   last run survives a resume and derive reports it.
///
/// Deliberately not ported (said plainly): no background scheduler or
/// supervisor — runs are inline, the command handler holds until the
/// run ends; no parallel fan-out (concurrent node turns on one loop
/// would interleave turn entries in the log; the engine's component
/// nodes fail a run with a clear reason); no `launch_workflow` model
/// tool (a tool executor runs *inside* a turn, and a node turn must not
/// nest inside one); no per-run run-store directory (the log is the
/// audit trail; attractor's in-memory store satisfies the engine); no
/// node-level model overrides (`llm_model`/`llm_provider` attributes
/// are ignored — one session, one provider); the loop-budget hook is
/// not wired, so an over-budget run fails instead of pausing to ask.
library;

import 'dart:async';

import 'dart:io';

import 'package:attractor/attractor.dart';
import 'package:path/path.dart' as path;
import 'package:tina_engine_2/tina_engine_2.dart' hide Outcome;
import 'package:tina_services/tina_services.dart';

import 'plugins.dart' show MountsTools;

/// Where workflow definitions live, relative to the session's tina dir.
const String workflowsDirName = 'workflows';

/// Workflow-name hygiene, ported verbatim from the old app's
/// `workflow_names.dart`: names become file names (`<name>.dot` under
/// the workflows dir) at every entry point, so the guard lives in one
/// place. True when [name] is safe to join into
/// `<workflowsDir>/<name>.dot`: non-empty, no path separators, no `..`,
/// no control characters — `../evil` must not escape the dir.
bool isSafeWorkflowName(String name) {
  final n = name.trim();
  if (n.isEmpty) return false;
  if (n.contains('/') || n.contains('\\')) return false;
  if (n == '.' || n == '..' || n.contains('..')) return false;
  return !n.runes.any((r) => r < 0x20 || r == 0x7f);
}

/// Normalize user-typed input: trim, drop a typed `.dot` suffix (the
/// caller appends it). Null when the result is empty or unsafe — pair
/// with [workflowNameRejection] for the reason.
String? normalizeWorkflowName(String input) {
  var n = input.trim();
  if (n.toLowerCase().endsWith('.dot')) {
    n = n.substring(0, n.length - 4).trim();
  }
  return isSafeWorkflowName(n) ? n : null;
}

/// Why [normalizeWorkflowName] rejected a name.
const String workflowNameRejection =
    'workflow names must be non-empty and may not '
    'contain "/", "\\", "..", or a typed ".dot" suffix';

/// The seeded default graph — the old app's default workflow with the
/// parallel fan-out (fanout → exec_1/2/3 → fanin) reduced to one
/// executor node, because parallel is deliberately not ported. The
/// intake, the double review, the clarify gate and the verdict routing
/// are the old graph's, carried over. The `\\n` escapes inside prompts
/// are DOT string escapes the parser resolves.
const String kDefaultWorkflowDotSource = '''
digraph default {
  graph [goal="Turn the user request into a reviewed plan, execute it, then review the result."]

  start [shape=Mdiamond, label="Start"]

  intake [shape=box, label="Intake",
        system_prompt="You are the intake step of a coding workflow. A user request is provided to you. Explore the repository enough to ground the request in real code (read files before concluding anything). You do not write code and you do not finalize a plan yourself: hand clear requirements and your findings to the plan node.",
        prompt="User request: \$input\\n\\nExplore the repository enough to ground the request. Then summarize the requirements and your findings. The plan node will plan from your summary."]

  plan [shape=box, label="Plan", context="intake",
        system_prompt="You are a planning agent. You turn requirements and findings into a concrete plan that other agents can execute. You do not write code; you plan.",
        prompt="Using the intake summary above, write a concrete plan: the files to change, the steps in order, the risks, and how to verify. Output only the plan."]

  plan_review_1 [shape=box, label="Plan review (1)", context="plan", writes="plan",
        system_prompt="You are a careful, independent plan reviewer. You check the plan above for correctness, completeness, and risk. Your response becomes the working plan for the executor: always restate the plan in full — unchanged if it is sound, revised if you improve it — WHATEVER your verdict, so the plan is never replaced by a question or a fragment.",
        prompt="Review the plan above. First, restate the full plan (unchanged if sound; your full revision if you improved it) — your response IS the working plan the executor will implement. Then end with exactly one of:\\nVERDICT: approve — the restated plan is sound\\nVERDICT: revise — you restated an improved plan\\nVERDICT: clarify — AFTER the full restated plan, state the question you need the user to decide (one or two sentences)\\nOutput nothing after the VERDICT line."]

  plan_review_2 [shape=box, label="Plan review (2)", context="plan", writes="plan",
        system_prompt="You are a careful, independent plan reviewer. You check the plan above for correctness, completeness, and risk. Your response becomes the working plan for the executor: always restate the plan in full — unchanged if it is sound, revised if you improve it — WHATEVER your verdict, so the plan is never replaced by a question or a fragment.",
        prompt="Review the plan above. First, restate the full plan (unchanged if sound; your full revision if you improved it) — your response IS the working plan the executor will implement. Then end with exactly one of:\\nVERDICT: approve — the restated plan is sound\\nVERDICT: revise — you restated an improved plan\\nVERDICT: clarify — AFTER the full restated plan, state the question you need the user to decide (one or two sentences)\\nOutput nothing after the VERDICT line."]

  clarify [shape=hexagon, label="The reviewer needs a decision from you before continuing.",
        prompt="\$last_stage\\n\\nThe reviewer needs a decision from you before continuing. Pick how to proceed."]

  exec_1 [shape=box, label="Executor", context="plan",
        system_prompt="You are an implementation agent. You execute an approved plan. Read each file before editing it, make only the changes the plan requires, keep changes minimal, and report exactly what you changed.",
        prompt="The plan above is approved. Implement it now and report exactly what you changed."]

  exec_reviewer [shape=box, label="Execution review", context="plan",
        system_prompt="You are a results reviewer. The result above comes from the executor that implemented the plan.",
        prompt="Review the result above against the plan. Did it get implemented correctly? Note any errors or incomplete work, summarize the outcome for the user in a few sentences, and flag anything that needs follow-up."]

  done [shape=Msquare, label="Done"]

  start -> intake
  intake -> plan
  plan -> plan_review_1

  plan_review_1 -> plan_review_2 [label="approve"]
  plan_review_1 -> plan_review_1 [label="revise"]
  plan_review_1 -> clarify [label="clarify"]

  clarify -> plan_review_1 [label="[R] Re-review with this in mind"]
  clarify -> plan_review_2 [label="[A] Approve and continue"]

  plan_review_2 -> exec_1 [label="approve"]
  plan_review_2 -> plan_review_2 [label="revise"]
  plan_review_2 -> clarify [label="clarify"]

  exec_1 -> exec_reviewer
  exec_reviewer -> done
}
''';

/// Write the seed workflow to `<workflowsDir>/default.dot`, creating the
/// directory if needed. Idempotent: true only when a new file was
/// written. The FILE is the override mechanism — once it exists it
/// shadows the catalog's built-in entry, and deleting it returns to the
/// built-in.
bool seedDefaultWorkflow(Directory workflowsDir) {
  final file = File(path.join(workflowsDir.path, 'default.dot'));
  if (file.existsSync()) return false;
  workflowsDir.createSync(recursive: true);
  file.writeAsStringSync(kDefaultWorkflowDotSource);
  return true;
}

/// Owns workflow-name → DOT-source resolution over one workflows dir.
/// The old `WorkflowCatalog` ported with its semantics pinned: a file
/// on disk always wins over a registered entry of the same name;
/// [list] is the on-disk scan only (registered entries are a
/// resolution fallback, never list items — deleting the seeded file
/// must return to the empty list, not expose the built-in).
class WorkflowCatalog {
  /// The name the built-in seed graph is registered under.
  static const String defaultEntryName = 'default';

  /// The workflows dir this catalog scans.
  final Directory workflowsDir;

  final Map<String, String> _entries;

  /// A catalog over [workflowsDir] with no built-in entries: purely the
  /// on-disk scan.
  WorkflowCatalog({
    required this.workflowsDir,
    Map<String, String> entries = const {},
  }) : _entries = Map.of(entries);

  /// The app's catalog: the on-disk scan plus the built-in seed graph
  /// under [defaultEntryName], with any [entries] layered on top.
  factory WorkflowCatalog.standard({
    required Directory workflowsDir,
    Map<String, String> entries = const {},
  }) {
    return WorkflowCatalog(
      workflowsDir: workflowsDir,
      entries: {...entries, defaultEntryName: kDefaultWorkflowDotSource},
    );
  }

  /// Register a programmatic entry. Never overrides a file on disk —
  /// files win by construction ([read]).
  void register(String name, String dotSource) => _entries[name] = dotSource;

  /// Every launchable workflow name — the `*.dot` files in the
  /// workflows dir, extensionless, sorted. Empty when the dir is absent
  /// or holds no workflows.
  List<String> list() {
    if (!workflowsDir.existsSync()) return const [];
    return workflowsDir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.endsWith('.dot'))
        .map((f) => path.basenameWithoutExtension(f.path))
        .toList()
      ..sort();
  }

  /// Resolve [name] to its DOT source: the on-disk `<name>.dot` when
  /// present, else a registered entry (only while the workflows dir
  /// exists). Throws a [FileSystemException] carrying
  /// [workflowNameRejection] for an unsafe name and one carrying
  /// `'workflow not found'` when nothing answers.
  Future<String> read(String name) async {
    if (!isSafeWorkflowName(name)) {
      throw FileSystemException(
        workflowNameRejection,
        path.join(workflowsDir.path, '<name>.dot'),
      );
    }
    final file = File(path.join(workflowsDir.path, '$name.dot'));
    if (await file.exists()) return file.readAsString();
    if (workflowsDir.existsSync()) {
      final entry = _entries[name];
      if (entry != null) return entry;
    }
    throw FileSystemException('workflow not found', file.path);
  }
}

/// A workflow that parsed and validated: ready to run.
final class PreparedWorkflow {
  final String name;
  final Graph graph;

  const PreparedWorkflow(this.name, this.graph);

  String get goal => graph.goal;
}

/// Why a workflow could not be prepared: an unsafe name, a missing
/// file, DOT that does not parse, or a graph that fails validation.
/// The command renders the message; tests assert on it.
final class WorkflowProblem implements Exception {
  final String message;
  WorkflowProblem(this.message);

  @override
  String toString() => message;
}

/// One workflow node's turn, as the node handler assembles it: the node
/// id, the system prompt the node declares, and the fully expanded task
/// (preamble of prior outputs + the node's own prompt). Exposed so a
/// test can pin what a node would ask the model.
final class NodeTurn {
  final String nodeId;
  final String systemPrompt;
  final String task;

  const NodeTurn(this.nodeId, this.systemPrompt, this.task);

  @override
  String toString() => 'NodeTurn($nodeId, ${task.length} chars)';
}

/// The node turn runner: turns [nodeTurn] into one real turn on
/// [loop]. The default is [runNodeTurn]; injectable only so tests can
/// pin node outputs without scripting a whole provider — production
/// always runs the real thing.
typedef NodeTurnRunner = Future<String> Function(
    AgentLoop loop, NodeTurn nodeTurn);

/// The plugin: owns the workflows dir, the `/workflow` command, and the
/// seam that runs a graph's nodes as turns on the session's loop.
final class WorkflowsPlugin extends AgentPlugin implements MountsTools {
  WorkflowsPlugin({
    this.id = 'workflows',
    this.order = 30,
    required Directory tinaDir,
    this.seedOnMount = true,
    NodeTurnRunner? runNodeTurn,
    Services? services,
  })  : tinaDir = tinaDir,
        _runNodeTurn = runNodeTurn,
        services = services;

  @override
  final String id;

  /// After goals (25) — the workflow section is the least pressing.
  @override
  final int order;

  /// The session's tina dir; `<tinaDir>/workflows/` is the catalog's
  /// scan root, created on demand by the seeding.
  final Directory tinaDir;

  /// Seed `<tinaDir>/workflows/default.dot` at mount. On: the file is
  /// the override mechanism, and first run needs a graph.
  final bool seedOnMount;

  final NodeTurnRunner? _runNodeTurn;

  AgentLoop? _loop;
  bool _published = false;

  /// The session's shared services, for the `/workflow` command. Null
  /// means no command — the engine-facing surface still works.
  final Services? services;

  /// The workflows dir: `<tinaDir>/workflows`.
  Directory get workflowsDir =>
      Directory(path.join(tinaDir.path, workflowsDirName));

  /// The last run's outcome as the log carries it — null when no run
  /// has ended. Kept current by [mountOn]'s subscription; the same fact
  /// a resume's derive reports ([DerivedSession.workflowRun]).
  SessionWorkflowRun? lastRun;

  @override
  List<ToolSchema> get tools => const [];

  /// The model-facing section: that named workflows exist and that
  /// running one is the user's command, not a tool call. No workflows
  /// on disk → no section — silence is not noise.
  @override
  void onPrompt(TurnContext c) {
    final names = _catalog().list();
    if (names.isEmpty) return;
    c.promptSections.add(
      '<workflows>\n'
      'Named workflows are available in this session: '
      '${names.join(", ")}.\n'
      'A workflow is a graph of agent steps the user runs with '
      '`/workflow run <name>`; each step of a run executes as a real '
      'turn, so the log shows every node\'s work.\n'
      'You cannot start a run yourself — running one is a user '
      'command, not a tool call. If the user asks for a workflow, tell '
      'them the command.\n'
      '</workflows>',
    );
  }

  /// Mount: seed the dir, replay the log into [lastRun] (a resumed
  /// session reports the same last-run fact the running one had), and
  /// publish the command. No executor: the plugin contributes no tool.
  @override
  void mountOn(AgentLoop loop) {
    if (_loop != null) return;
    _loop = loop;
    if (seedOnMount) seedDefaultWorkflow(workflowsDir);
    for (final e in loop.log.whereType<WorkflowRunEntry>()) {
      lastRun = _asRun(e);
    }
    loop.subscribe((entry, event) {
      if (entry is WorkflowRunEntry) lastRun = _asRun(entry);
    });
    register();
  }

  static SessionWorkflowRun _asRun(WorkflowRunEntry e) =>
      SessionWorkflowRun(
          workflow: e.workflow,
          status: e.status,
          detail: e.detail,
          nodes: e.nodes);

  WorkflowCatalog _catalog() =>
      WorkflowCatalog.standard(workflowsDir: workflowsDir);

  /// Parse + validate `<name>` from the catalog. Throws
  /// [WorkflowProblem] with the reason on anything unusable.
  Future<PreparedWorkflow> prepare(String name) async {
    final String source;
    try {
      source = await _catalog().read(name);
    } on FileSystemException catch (e) {
      throw WorkflowProblem('workflow "$name": ${e.message}');
    }
    final Graph graph;
    try {
      graph = parseDot(source);
    } on DotParseError catch (e) {
      throw WorkflowProblem('workflow "$name" is not valid DOT: $e');
    }
    final errors =
        validate(graph).where((d) => d.severity == Severity.error).toList();
    if (errors.isNotEmpty) {
      throw WorkflowProblem(
          'workflow "$name" is invalid: ${errors.map((d) => '$d').join('; ')}');
    }
    return PreparedWorkflow(name, graph);
  }

  /// Run [name] to completion, reporting through [terminal]. Nodes run
  /// inline on the session's loop; the future completes when the run
  /// does. Records one [WorkflowRunEntry] through `recordState` when
  /// the run reaches a verdict (success or fail). A cancelled run —
  /// the user cancelling the session mid-node — is undecided, records
  /// nothing, and says so.
  Future<void> run({
    required String name,
    required Terminal terminal,
    String? input,
  }) async {
    final loop = _loop;
    if (loop == null) {
      throw StateError('WorkflowsPlugin.mountOn first');
    }
    final PreparedWorkflow prepared;
    try {
      prepared = await prepare(name);
    } on WorkflowProblem catch (e) {
      terminal.writeln(e.message);
      return;
    }
    final graph = prepared.graph;
    terminal.writeln(
        '▶ workflow ${prepared.name}'
        '${graph.goal.isEmpty ? '' : ' — ${graph.goal}'}');

    // The in-memory store doubles as the run's node record: handlers
    // write each node's prompt/response there, and the tracking wrapper
    // records the executed node ids for the outcome entry. (The old app
    // wrote the same records to a per-run directory; the log is this
    // engine's audit trail, so the directory went with the scheduler.)
    final runStore = MemoryRunStore();
    final executed = _RunNodes();
    NodeHandler tracked(NodeHandler inner) =>
        _TrackingHandler(inner, executed);

    final registry = NodeHandlerRegistry()
      ..register('start', tracked(StartHandler()))
      ..register('exit', tracked(ExitHandler()))
      ..register('conditional', tracked(ConditionalHandler()))
      ..register('wait.human',
          tracked(HumanGateHandler(TerminalInterviewer(terminal))))
      ..register('codergen',
          tracked(_NodeTurnHandler(loop, _runNodeTurn ?? _defaultRunNodeTurn)));
    // Parallel fan-out/fan-in and tool nodes are deliberately not
    // ported; an unknown-type node fails the run with a clear reason
    // instead of silently doing nothing.
    registry.defaultHandler = _UnsupportedHandler();

    final outcome = await PipelineEngine(
      graph: graph,
      registry: registry,
      runStore: runStore,
      runId: 'w-${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}',
      workflowName: prepared.name,
      // A node turn already streamed to the user; a retry loop that
      // sleeps adds nothing to an inline run. Tests stay instant.
      backoffFor: (_) => Duration.zero,
      onEvent: (e) => _renderEvent(terminal, e),
    ).run(input: input);

    switch (outcome.status) {
      case StageStatus.success || StageStatus.partialSuccess:
        final detail = outcome.text.isNotEmpty ? outcome.text : outcome.notes;
        loop.recordState(WorkflowRunEntry.record(
          workflow: prepared.name,
          status: WorkflowRunEntry.statusSuccess,
          detail: detail,
          nodes: executed.ids,
        ));
        terminal.writeln('✔ recorded: ${prepared.name} succeeded');
      case StageStatus.fail:
        // A node-turn cancellation surfaces here as a plain fail — the
        // engine converts any handler throw into one. But the user
        // stopping the session is not the workflow's judgement, so the
        // marker is checked before anything is recorded.
        if (_isCancelledReason(outcome.failureReason)) {
          terminal.writeln('○ run not recorded: cancelled');
          return;
        }
        loop.recordState(WorkflowRunEntry.record(
          workflow: prepared.name,
          status: WorkflowRunEntry.statusFailed,
          detail: outcome.failureReason,
          nodes: executed.ids,
        ));
        terminal.writeln('✖ recorded: ${prepared.name} failed');
      default:
        // A cancelled (or otherwise undecided) run leaves no verdict:
        // the user stopped the session, which is not the workflow's
        // judgement to record.
        terminal.writeln('○ run not recorded: ${outcome.status.wire}');
    }
  }

  /// True when a fail outcome carries the node-turn cancellation
  /// marker — the engine's generic wrapper text plus
  /// [WorkflowCancelled]'s message. Substring, not equality: the
  /// engine's wording is its own.
  static bool _isCancelledReason(String reason) =>
      reason.contains('cancelled at node');

  void _renderEvent(Terminal terminal, PipelineEvent e) {    switch (e.kind) {
      case 'node_started':
        terminal.writeln('▶ ${e.nodeId}');
      case 'node_retrying':
        terminal.writeln('↻ ${e.nodeId}: ${e.message}');
      case 'node_failed':
        terminal.writeln('✖ ${e.nodeId}: ${e.message}');
      case 'completed':
        break; // the recording notice below carries the ending
      case 'failed':
        terminal.writeln('✖ workflow failed: ${e.message}');
    }
  }

  /// The user's surface: `/workflow` — `list` (default), `run <name>
  /// [input...]`, `show <name>`, `last`.
  void register() {
    final locator = services;
    if (locator == null || _published) return;
    locator.get<Commands>().publish(Command(
          name: 'workflow',
          description:
              'list workflows, run one (/workflow run <name> [input]), '
              'show one, or show the last run',
          handler: _workflowCommand,
        ));
    _published = true;
  }

  void _workflowCommand(String argument) {
    final terminal = services!.get<Terminal>();
    final parts = argument.trim().split(RegExp(r'\s+'));
    final sub = parts.isEmpty || parts.first.isEmpty ? 'list' : parts.first;

    switch (sub) {
      case 'list':
        _list(terminal);
      case 'run':
        if (parts.length < 2) {
          terminal.writeln('usage: /workflow run <name> [input...]');
          return;
        }
        final name = normalizeWorkflowName(parts[1]);
        if (name == null) {
          terminal.writeln(workflowNameRejection);
          return;
        }
        final rest = parts.length > 2 ? parts.sublist(2).join(' ') : '';
        unawaited(run(
          name: name,
          terminal: terminal,
          input: rest.isEmpty ? null : rest,
        ));
      case 'show':
        if (parts.length < 2) {
          terminal.writeln('usage: /workflow show <name>');
          return;
        }
        unawaited(_show(terminal, parts[1]));
      case 'last':
        _showLast(terminal);
      default:
        terminal.writeln(
            'usage: /workflow [list | run <name> [input...] | '
            'show <name> | last]');
    }
  }

  void _list(Terminal terminal) {
    final names = _catalog().list();
    if (names.isEmpty) {
      terminal.writeln('no workflows in ${workflowsDir.path} — add a .dot file');
      return;
    }
    terminal.writeln('workflows:');
    for (final n in names) {
      terminal.writeln('  $n');
    }
    terminal.writeln('run one: /workflow run <name> [input...]');
  }

  Future<void> _show(Terminal terminal, String rawName) async {
    final name = normalizeWorkflowName(rawName);
    if (name == null) {
      terminal.writeln(workflowNameRejection);
      return;
    }
    try {
      final prepared = await prepare(name);
      terminal.writeln('workflow $name'
          '${prepared.goal.isEmpty ? '' : ' — ${prepared.goal}'}');
      for (final n in prepared.graph.nodes.values) {
        terminal.writeln('  ${n.id}: ${n.handlerType}');
      }
    } on WorkflowProblem catch (e) {
      terminal.writeln(e.message);
    }
  }

  void _showLast(Terminal terminal) {
    final run = lastRun;
    if (run == null) {
      terminal.writeln('no workflow run recorded yet in this session');
      return;
    }
    terminal.writeln(
        'last run: ${run.workflow} — ${run.status}'
        '${run.nodes.isEmpty ? '' : ' (${run.nodes.join(" → ")})'}');
    if (run.detail.isNotEmpty) terminal.writeln('  ${run.detail}');
  }
}

/// The node ids that executed, in execution order — appended by the
/// tracking wrapper as the engine dispatches each node.
final class _RunNodes {
  final List<String> _ids = [];
  void add(String id) => _ids.add(id);
  List<String> get ids => List.unmodifiable(_ids);
}

/// Wraps a handler so the run's node list records every node the engine
/// dispatched, whatever the handler decided — the audit fact is "this
/// node ran", independent of its verdict.
final class _TrackingHandler implements NodeHandler {
  final NodeHandler _inner;
  final _RunNodes _executed;
  _TrackingHandler(this._inner, this._executed);

  @override
  Future<Outcome> execute({
    required PipelineNode node,
    required Graph graph,
    required Context context,
    required RunStore runStore,
    Future<void>? cancelSignal,
    PipelineEventListener? onEvent,
  }) {
    _executed.add(node.id);
    return _inner.execute(
      node: node,
      graph: graph,
      context: context,
      runStore: runStore,
      cancelSignal: cancelSignal,
      onEvent: onEvent,
    );
  }
}

/// Run one node's turn on the session's loop: the node's task becomes
/// the turn's input, the node's system prompt is carried in the input
/// itself (a turn has one system prompt — the session's — so the node's
/// identity rides as a header the model reads first). The reply text is
/// what the engine records under `context.<nodeId>` for downstream
/// nodes.
Future<String> _defaultRunNodeTurn(AgentLoop loop, NodeTurn nodeTurn) async {
  final input = nodeTurn.systemPrompt.isEmpty
      ? nodeTurn.task
      : '[workflow node: ${nodeTurn.nodeId}]\n'
          'Identity for this turn: ${nodeTurn.systemPrompt}\n\n'
          '${nodeTurn.task}';
  final outcome = await loop.runTurn(
      Input(input, id: 'wf-${nodeTurn.nodeId}-${loop.seq}'));
  switch (outcome.stopReason) {
    case StopReason.complete:
      return outcome.detail;
    case StopReason.cancelled:
      throw WorkflowCancelled(nodeTurn.nodeId);
    case StopReason.error:
      throw WorkflowNodeError(nodeTurn.nodeId, outcome.detail);
  }
}

/// A node's turn was cancelled — the user stopped the session. The
/// message text is matched upstream (through the engine's generic
/// handler-error wrapper) to keep a cancelled run from being recorded
/// as a failed verdict; change it and change
/// [WorkflowsPlugin._isCancelledReason] with it.
final class WorkflowCancelled implements Exception {
  final String nodeId;
  WorkflowCancelled(this.nodeId);

  @override
  String toString() => 'cancelled at node "${nodeId}"';
}

/// A node's turn ended in a provider error.
final class WorkflowNodeError implements Exception {
  final String nodeId;
  final String detail;
  WorkflowNodeError(this.nodeId, this.detail);

  @override
  String toString() => 'node "${nodeId}" failed: $detail';
}

/// The `codergen` handler: expand + assemble the node's prompt the way
/// attractor's own handler does, then run it as one turn on the
/// session's loop. A [WorkflowCancelled] propagates out of `execute`
/// (the engine converts any handler throw into a fail outcome — but a
/// cancelled run must stay undecided, so [WorkflowsPlugin.run] rethrows
/// the cancelled marker before any recording happens; the engine's
/// fail outcome for it is simply never recorded).
final class _NodeTurnHandler implements NodeHandler {
  final AgentLoop _loop;
  final NodeTurnRunner _runner;

  _NodeTurnHandler(this._loop, this._runner);

  @override
  Future<Outcome> execute({
    required PipelineNode node,
    required Graph graph,
    required Context context,
    required RunStore runStore,
    Future<void>? cancelSignal,
    PipelineEventListener? onEvent,
  }) async {
    final rawPrompt = node.prompt.isNotEmpty ? node.prompt : node.label;
    final prompt = expandTemplate(rawPrompt, context);
    final preamble =
        buildPreamble(context, keys: node.contextKeys);
    final task = preamble.isEmpty ? prompt : '$preamble\n\n$prompt';
    final identity = node.systemPrompt;
    try {
      final response = await _runner(
          _loop, NodeTurn(node.id, identity, task));
      final verdict = parseWorkflowVerdict(response);
      return Outcome.success(
        contextUpdates: {
          node.id: response,
          for (final w in node.writesKeys)
            if (w != node.id) w: response,
          'last_stage': node.id,
          'last_response': _truncate(response, 200),
        },
        preferredLabel: verdict,
        notes: 'stage completed: ${node.id}',
      );
    } on WorkflowCancelled {
      rethrow;
    } on WorkflowNodeError catch (e) {
      return Outcome.fail(e.toString());
    }
  }
}

/// Extract a trailing `VERDICT: <label>` line (case-insensitive), the
/// old backend's convention, so a reviewer node routes on its own
/// decision: the label becomes [Outcome.preferredLabel], which the
/// engine matches against an edge's label. Null when there is none.
String? parseWorkflowVerdict(String text) {
  final lines = text.trimRight().split('\n');
  while (lines.isNotEmpty && lines.last.trim().isEmpty) {
    lines.removeLast();
  }
  if (lines.isEmpty) return null;
  final m = RegExp(
    r'VERDICT:\s*([A-Za-z0-9_\-]+)',
    caseSensitive: false,
  ).firstMatch(lines.last);
  return m?.group(1)?.toLowerCase();
}

/// The human gate on the session's terminal: choices listed, answer
/// read with `ask`. The old headless auto-yes interviewer is replaced
/// by a real question — an inline run holds the command, so blocking on
/// the user is exactly right. Cancel (empty answer) fails the gate,
/// which the engine records as the run's failure.
final class TerminalInterviewer implements Interviewer {
  final Terminal terminal;
  TerminalInterviewer(this.terminal);

  @override
  Future<Answer> ask(Question question) async {
    terminal.writeln('? ${question.text}');
    final options = question.options ?? const <Option>[];
    for (final o in options) {
      terminal.writeln('  ${o.toString()}');
    }
    final line = await terminal.ask('> ');
    final typed = line.trim();
    if (typed.isEmpty) return const Answer.cancelled();
    // Match the typed word to a choice the old gate handler's Answer
    // matching matched: by accelerator key (case-insensitive), then by
    // label. Whatever matched rides as the value; the handler's
    // `_matchChoice` does the same lookup and falls back to the first
    // choice — never a silent wrong turn from a typo'd label alone.
    Option? match;
    for (final o in options) {
      if (o.key.toLowerCase() == typed.toLowerCase() ||
          o.label == typed) {
        match = o;
        break;
      }
    }
    return Answer(value: match?.key ?? typed, selectedOption: match);
  }

  @override
  Future<void> inform(String message, {String? stage}) async {
    terminal.writeln(message);
  }
}

/// The default handler for node types this port does not carry
/// (`parallel`, `parallel.fan_in`, `tool`, …): a clear failure instead
/// of a silent no-op.
final class _UnsupportedHandler implements NodeHandler {
  @override
  Future<Outcome> execute({
    required PipelineNode node,
    required Graph graph,
    required Context context,
    required RunStore runStore,
    Future<void>? cancelSignal,
    PipelineEventListener? onEvent,
  }) async =>
      Outcome.fail(
          'node "${node.id}" has type "${node.handlerType}", which this '
          'workflow runner does not support (parallel and tool nodes are '
          'not ported)');
}

String _truncate(String s, int max) =>
    s.length <= max ? s : '${s.substring(0, max)}…';
