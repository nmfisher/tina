// The default chat workflow + helpers. Pure helpers + the seed file —
// deliberately free of tina_console and PipelineRunner so other layers can use
// it without crossing the import boundary (see test/import_boundary_test.dart).
//
// Model (manager loop): the main agent runs OUTSIDE any workflow. Normal turns
// run the plain agent; a workflow is launched on demand by the agent's
// `launch_workflow` tool (the default graph by default). This file seeds the
// launchable default graph and supplies the helpers that name/validate it. See
// docs/features/manager_loop.md.
library;

import 'dart:io';

import 'package:attractor/attractor.dart';
import 'package:path/path.dart' as p;
import 'package:tina_engine/tina_engine.dart';

/// Cap for the chat transcript injected as `$history` (~15k tokens).
const int kHistoryMaxChars = 60000;

/// Serialize [history] as `user:` / `assistant:` text lines, oldest first,
/// newest kept (older messages are dropped first once the cap is hit). Tool
/// blocks are skipped. The newest message is always included; if it alone
/// exceeds [maxChars], its head is kept.
String formatChatHistory(List<Message> history,
    {int maxChars = kHistoryMaxChars}) {
  // Newest first, text blocks only.
  final blocks = <String>[];
  for (final m in history.reversed) {
    final text =
        m.content.whereType<TextBlock>().map((b) => b.text).join('\n').trim();
    if (text.isEmpty) continue;
    final label = m.role == Role.user ? 'user' : 'assistant';
    blocks.add('$label: $text');
  }
  if (blocks.isEmpty) return '';

  // Keep the newest messages until the cap; a blank line separates entries.
  final kept = <String>[];
  var used = 0;
  for (final b in blocks) {
    final cost = b.length + 2;
    if (used + cost > maxChars) break;
    kept.add(b);
    used += cost;
  }
  if (kept.isEmpty) {
    kept.add(blocks.first.length <= maxChars
        ? blocks.first
        : '${blocks.first.substring(0, maxChars)}…');
  }
  return kept.reversed.join('\n\n');
}

/// Resolve the conventional "default" workflow file.
///
/// Returns the name of the default graph (`default.dot`, or the one named by
/// `[default] workflow`), or null when none applies. This names the default the
/// main agent launches via its `launch_workflow` tool, shown by `/workflow
/// list`. `configured` is the `[default] workflow` config value: `"none"` is
/// explicit; a name requires that `<name>.dot` to exist; null/empty means the
/// conventional `default.dot` when present.
String? resolveDefaultWorkflowName({
  required String? configured,
  required Directory? workflowsDir,
}) {
  if (workflowsDir == null || !workflowsDir.existsSync()) return null;
  if (configured == 'none') return null;
  final name =
      (configured == null || configured.isEmpty) ? 'default' : configured;
  if (!File(p.join(workflowsDir.path, '$name.dot')).existsSync()) return null;
  return name;
}

/// A default workflow could not be used (missing, unparseable, or failing
/// validation) — the caller falls back to the plain agent and shows [message].
class DefaultWorkflowUnusable implements Exception {
  final String message;
  DefaultWorkflowUnusable(this.message);

  @override
  String toString() => message;
}

/// Throw [DefaultWorkflowUnusable] if `<dir>/<name>.dot` cannot be parsed and
/// validated. (Unknown roles are only warnings — they fail at runtime with a
/// clear message instead.)
Future<void> ensureDefaultWorkflowUsable(
    Directory workflowsDir, String name) async {
  final file = File(p.join(workflowsDir.path, '$name.dot'));
  final String source;
  try {
    source = await file.readAsString();
  } on FileSystemException catch (e) {
    throw DefaultWorkflowUnusable('workflow "$name" not found (${e.path})');
  }

  final Graph graph;
  try {
    graph = parseDot(source);
  } on DotParseError catch (e) {
    throw DefaultWorkflowUnusable('workflow "$name" is not valid DOT: $e');
  }

  final errors =
      validate(graph).where((d) => d.severity == Severity.error);
  if (errors.isNotEmpty) {
    throw DefaultWorkflowUnusable(
        'workflow "$name" is invalid: ${errors.map((d) => '$d').join('; ')}');
  }
}

/// The seeded default chat workflow — the launchable default graph, launched on
/// demand by the main agent's `launch_workflow` tool. It never wraps a chat turn
/// (the main agent runs outside the workflow — see docs/features/manager_loop.md).
/// A run flows:
///
///   intake          explore the repo and summarize the request (PLACEHOLDER:
///                   the intake node explores via its file tools and read-only
///                   delegation; a dedicated explore node/tool is future work)
///   plan            develop the plan, pass it to the first reviewer
///   plan_review_1   review the plan: approve / revise / clarify (human gate)
///   plan_review_2   a FRESH second pass of the same reviewer identity
///   fanout          on the second approve, fan out to exec_1/2/3 in parallel
///   fanin           merge the parallel results (tripleoctagon)
///   exec_reviewer   review the execution result
///   done
///
/// Design notes (see docs for the full write-up):
/// * **Double review** is two sequential nodes (`plan_review_1`, `plan_review_2`)
///   sharing one reviewer `system_prompt`. Each node visit is already a fresh
///   one-shot agent, so the second pass is automatically fresh — no per-node
///   visit counter or condition is needed.
/// * **Revise** loops to a fresh pass of the SAME review node (the reviewer
///   updates the plan itself), not back to the `plan` node. The plan evolves as
///   a chain of revisions carried forward in each downstream node's preamble;
///   the most recent revision is the current plan.
/// * **Parallel fan-out** uses the engine's `component` (fan-out) +
///   `tripleoctagon` (fan-in) handlers. Each branch is a single executor node
///   run against a cloned context; the fan-in merges them into one result.
///
/// A codergen node (box) carries its own `system_prompt` (identity) and optional
/// `llm_model` + `llm_provider` (model); omit the model attrs to inherit the
/// conversation's model. Routing between nodes uses a trailing
/// `VERDICT: <label>` line, matched against an edge's label. `intake` and the
/// executors can also delegate sub-agents with the `delegate` tool (a task plus
/// an optional tool profile: read-only for exploration/review, full for
/// changes). `$input` is the user's message and `$history` the (truncated) chat
/// transcript, both expanded by the engine at run time.
const String kDefaultWorkflowDotSource = '''
// tina's default chat workflow: the launchable default graph, launched on demand
// by the main agent's launch_workflow tool (the main agent runs outside the
// workflow; see docs/features/manager_loop.md). Edit with /workflow edit default.
//
// Flow:
//   intake          explore the repo and summarize the request
//   plan            develop the plan, pass it to the first reviewer
//   plan_review_1   review the plan; approve / revise / clarify (human gate)
//   plan_review_2   a FRESH second pass of the same reviewer identity
//   fanout          on the second approve, fan out to exec_1/2/3 in parallel
//   fanin           merge the parallel results
//   exec_reviewer   review the execution result
//   done
//
// A codergen node (box) carries its own system_prompt (identity) and optional
// llm_model + llm_provider (model); omit the model attrs to inherit the
// conversation's model. Routing between nodes uses a trailing VERDICT: <label>
// line, matched against an edge's label. intake and the executors can also
// delegate sub-agents with the delegate tool (task + optional tool profile:
// read-only for exploration/review, full for changes).

digraph default {
  graph [goal="Turn the user request into a reviewed plan, execute it in parallel, then review the result."]

  start [shape=Mdiamond, label="Start"]

  intake [shape=box, label="Intake",
        system_prompt="You are the intake step of a coding workflow. A user request and conversation context are provided to you. Explore the repository enough to ground the request in real code; delegate read-only sub-agents where that helps (each delegation is a task plus an optional tool profile: read-only for exploration or review, full for changes — and an optional model). You have file tools (read, write, edit, bash, search, grep, glob) and a delegate tool, but you do not write code and you do not finalize a plan yourself: hand clear requirements and your findings to the plan node.",
        prompt="User request: \$input\\n\\nConversation history for context:\\n\$history\\n\\nExplore the repository enough to ground the request (delegate read-only sub-agents where it helps). Then summarize the requirements and your findings. Do not write code yet. The plan node will plan from your summary."]

  plan [shape=box, label="Plan",
        system_prompt="You are a planning agent. You turn requirements and findings into a concrete plan that other agents can execute. You do not write code; you plan.",
        prompt="Using the intake summary above, write a concrete plan: the files to change, the steps in order, the risks, and how to verify. Because the work runs in parallel across three executors, divide it into up to three independent chunks labeled [1], [2], [3] so each executor takes one. If the work is small, use fewer chunks. Output only the plan."]

  plan_review_1 [shape=box, label="Plan review (1)",
        system_prompt="You are a careful, independent plan reviewer. You check the plan above for correctness, completeness, and risk. Treat the most recent version of the plan as the current one.",
        prompt="Review the plan above. If it is sound, end your response with exactly this line:\\nVERDICT: approve\\nIf you can improve it yourself, output the full revised plan and end with:\\nVERDICT: revise\\nIf you need a decision from the user, state the question in one or two sentences and end with:\\nVERDICT: clarify\\nOutput nothing after the VERDICT line."]

  plan_review_2 [shape=box, label="Plan review (2)",
        system_prompt="You are a careful, independent plan reviewer. You check the plan above for correctness, completeness, and risk. Treat the most recent version of the plan as the current one.",
        prompt="Review the plan above. If it is sound, end your response with exactly this line:\\nVERDICT: approve\\nIf you can improve it yourself, output the full revised plan and end with:\\nVERDICT: revise\\nIf you need a decision from the user, state the question in one or two sentences and end with:\\nVERDICT: clarify\\nOutput nothing after the VERDICT line."]

  clarify [shape=hexagon, label="The reviewer needs a decision from you before continuing. Pick how to proceed."]

  fanout [shape=component, label="Fan out"]

  exec_1 [shape=box, label="Executor 1",
        system_prompt="You are an implementation agent. You execute one chunk of an approved plan. You have the full tool set (read, write, edit, bash, search, grep, glob) and a delegate tool. Read each file before editing it, make only the changes your chunk requires, keep changes minimal, and leave other chunks alone.",
        prompt="The plan above is split into chunks labeled [1], [2], [3]. Execute ONLY chunk [1]. If the plan has no chunk [1], output: no work for executor 1. Otherwise implement chunk [1] now and report exactly what you changed."]

  exec_2 [shape=box, label="Executor 2",
        system_prompt="You are an implementation agent. You execute one chunk of an approved plan. You have the full tool set (read, write, edit, bash, search, grep, glob) and a delegate tool. Read each file before editing it, make only the changes your chunk requires, keep changes minimal, and leave other chunks alone.",
        prompt="The plan above is split into chunks labeled [1], [2], [3]. Execute ONLY chunk [2]. If the plan has no chunk [2], output: no work for executor 2. Otherwise implement chunk [2] now and report exactly what you changed."]

  exec_3 [shape=box, label="Executor 3",
        system_prompt="You are an implementation agent. You execute one chunk of an approved plan. You have the full tool set (read, write, edit, bash, search, grep, glob) and a delegate tool. Read each file before editing it, make only the changes your chunk requires, keep changes minimal, and leave other chunks alone.",
        prompt="The plan above is split into chunks labeled [1], [2], [3]. Execute ONLY chunk [3]. If the plan has no chunk [3], output: no work for executor 3. Otherwise implement chunk [3] now and report exactly what you changed."]

  fanin [shape=tripleoctagon, label="Fan in"]

  exec_reviewer [shape=box, label="Execution review",
        system_prompt="You are a results reviewer. The execution results above come from parallel executors that each took one chunk of the plan.",
        prompt="Review the execution results above. Did the plan get implemented correctly across the chunks? Note any errors, conflicts, or incomplete work. Summarize the outcome for the user in a few sentences and flag anything that needs follow-up."]

  done [shape=Msquare, label="Done"]

  start -> intake
  intake -> plan
  plan -> plan_review_1

  plan_review_1 -> plan_review_2 [label="approve"]
  plan_review_1 -> plan_review_1 [label="revise"]
  plan_review_1 -> clarify [label="clarify"]

  clarify -> plan_review_1 [label="[R] Re-review with this in mind"]
  clarify -> plan_review_2 [label="[A] Approve and continue"]

  plan_review_2 -> fanout [label="approve"]
  plan_review_2 -> plan_review_2 [label="revise"]
  plan_review_2 -> clarify [label="clarify"]

  fanout -> exec_1
  fanout -> exec_2
  fanout -> exec_3
  fanout -> fanin

  fanin -> exec_reviewer
  exec_reviewer -> done
}
''';

/// Write the seed workflow to <dir>/default.dot, creating the directory if
/// needed. Idempotent: returns true only when a new file was written.
bool seedDefaultWorkflow(Directory workflowsDir) {
  final file = File(p.join(workflowsDir.path, 'default.dot'));
  if (file.existsSync()) return false;
  workflowsDir.createSync(recursive: true);
  file.writeAsStringSync(kDefaultWorkflowDotSource);
  return true;
}
