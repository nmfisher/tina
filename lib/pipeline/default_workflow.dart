// Default-workflow routing for normal chat turns. Pure helpers + the seed
// file — deliberately free of tina_console and PipelineRunner so
// `session_controller.dart` can use it without crossing the import boundary
// (see test/import_boundary_test.dart).
//
// Contract: while `~/.tina/workflows/default.dot` exists (or a workflow named
// by `[default] workflow` in ~/.tina/config), every normal turn routes through
// that DOT pipeline; otherwise the plain single-agent path runs.
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

/// Resolve the workflow that a normal turn should route through.
///
/// Returns null when no default routing applies (fall back to the plain
/// agent). `configured` is the `[default] workflow` config value: `"none"`
/// disables routing explicitly; a name requires that `<name>.dot` to exist;
/// null/empty means the conventional `default.dot` when present.
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

/// The seeded default chat workflow: planner -> reviewer -> executor, with a
/// revise loop back to the planner. The executor node is an `orchestrator`
/// that splits the work and delegates to implementer sub-agents via the
/// `delegate` tool, so "one or more executors" needs no engine parallelism.
/// `$input` is the user's message and `$history` the (truncated) chat
/// transcript, both expanded by the engine at run time.
const String kDefaultWorkflowDotSource = '''
// tina's default chat workflow: every normal turn routes through this graph
// while this file exists. Edit with /workflow edit default; delete the file
// (or set [default] workflow = "none" in ~/.tina/config) to fall back to the
// plain single-agent path.

digraph default {
  start [shape=Mdiamond, label="Start"]

  plan [shape=box, role="orchestrator", label="Plan",
        prompt="Produce a concrete implementation plan for: \$input.\\nConversation history for context:\\n\$history\\nNumber the steps and reference specific files. End your response with a line VERDICT: submit."]

  review [shape=box, role="verifier", label="Review",
          prompt="Review the plan above for correctness, completeness, and ordering. Check that each step references specific files and respects dependencies. End your response with VERDICT: approve when the plan is sound, or VERDICT: revise followed by your comments when it needs changes."]

  execute [shape=box, role="orchestrator", label="Execute",
           prompt="Execute the approved plan. Where the work splits cleanly, delegate pieces to implementer sub-agents with the delegate tool and integrate their results; otherwise make the changes directly. Read each file before editing it. Report what was done."]

  done [shape=Msquare, label="Done"]

  start -> plan
  plan   -> review  [label="submit"]
  review -> execute [label="approve"]
  review -> plan    [label="revise"]
  execute -> done
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
