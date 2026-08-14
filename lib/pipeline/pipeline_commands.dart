import 'dart:io';

import 'package:tina_engine/tina_engine.dart';

import '../session_commands/command_context.dart';
import 'default_workflow.dart';
import 'pipeline_runner.dart';
import 'workflow_names.dart';

/// The `/workflow` slash command: `list`, `show`, `new`, `edit`. Dispatched
/// from [SessionCommandHandlers]. `list` reads directly from
/// [CommandContext.workflowsDir]; `show`/`new`/`edit` delegate to the
/// coordinator-wired slots. Workflows themselves are launched by the main
/// agent's `launch_workflow` tool, not from this command.
Future<void> handleWorkflowCommand(CommandContext ctx, String line) async {
  final parts = line.split(RegExp(r'\s+'));
  final sub = parts.length < 2 ? 'list' : parts[1];

  switch (sub) {
    case 'list':
      // A bare `/workflow` also prints usage hints; an explicit `list` stays
      // terse (the names are all it's for).
      await _list(ctx, hints: parts.length < 2);
    case 'show':
      await _show(ctx, parts);
    case 'new':
      await _new(ctx);
    case 'edit':
      await _edit(ctx, parts);
    default:
      ctx.active.host.showMessage(
          'usage: /workflow [list | show <name> | new | edit <name>]\n',
          style: HostMessageStyle.warning);
  }
}

Future<void> _list(CommandContext ctx, {bool hints = false}) async {
  final dir = ctx.workflowsDir;
  if (dir == null) {
    ctx.active.host
        .showMessage('(workflows unavailable)\n', style: HostMessageStyle.dim);
    return;
  }
  final names = PipelineRunner.listWorkflows(dir);
  if (names.isEmpty) {
    ctx.active.host.showMessage(
        '(no workflows in ${dir.path} — add a .dot file)\n',
        style: HostMessageStyle.dim);
    if (hints) _showHints(ctx);
    return;
  }
  // Which workflow, if any, is the conventional "default" graph (the seeded
  // default.dot, or one named by [default] workflow) — the one the main agent
  // launches by default via its `launch_workflow` tool.
  final defaultName = resolveDefaultWorkflowName(
      configured: ctx.defaultWorkflow, workflowsDir: dir);
  ctx.active.host.showMessage('workflows:\n');
  for (final n in names) {
    final isDefault = n == defaultName;
    ctx.active.host.showMessage(
        '  $n${isDefault ? '   ← default' : ''}\n',
        style: HostMessageStyle.dim);
  }
  if (hints) _showHints(ctx);
}

/// The usage/hints block a bare `/workflow` prints under the list.
void _showHints(CommandContext ctx) {
  final host = ctx.active.host;
  host.showMessage('\nusage:\n');
  host.showMessage(
      '  /workflow edit <name>             visual node editor (e/n/c/d/s keys)\n',
      style: HostMessageStyle.dim);
  host.showMessage('  /workflow new                     start a new skeleton\n',
      style: HostMessageStyle.dim);
  host.showMessage('  /workflow show <name>             view the graph\n',
      style: HostMessageStyle.dim);

  host.showMessage('\nhints:\n');
  host.showMessage(
      '  • workflows aren\'t launched from here — the main agent runs them via\n'
      '    its `launch_workflow` tool (the default graph by default). This\n'
      '    command only lists/views/edits the graphs\n',
      style: HostMessageStyle.dim);
  host.showMessage(
      '  • a node carries its own system_prompt (identity) and optional\n'
      '    llm_model + llm_provider (model). Omit the model attrs to inherit\n'
      '    the conversation model. A node delegates sub-agents with the\n'
      '    delegate tool (a task + an optional tool profile + model)\n',
      style: HostMessageStyle.dim);
  host.showMessage(
      '  • end a node\'s response with VERDICT: <label> to route on edge labels,\n'
      '    e.g. review -> execute [label="approve"] / review -> plan [label="revise"]\n',
      style: HostMessageStyle.dim);
}

Future<void> _show(CommandContext ctx, List<String> parts) async {
  final open = ctx.openWorkflowViewer;
  if (open == null) {
    // Headless fallback: print the raw DOT.
    await _showText(ctx, parts);
    return;
  }
  if (parts.length < 3) {
    ctx.active.host.showMessage('usage: /workflow show <name>\n',
        style: HostMessageStyle.warning);
    return;
  }
  if (!_checkName(ctx, parts[2])) return;
  await open(parts[2]);
}

Future<void> _showText(CommandContext ctx, List<String> parts) async {
  final dir = ctx.workflowsDir;
  if (dir == null) {
    ctx.active.host
        .showMessage('(workflows unavailable)\n', style: HostMessageStyle.dim);
    return;
  }
  if (parts.length < 3) {
    ctx.active.host.showMessage('usage: /workflow show <name>\n',
        style: HostMessageStyle.warning);
    return;
  }
  try {
    final source = await PipelineRunner.readWorkflow(dir, parts[2]);
    ctx.active.host.showSeparator();
    for (final ln in source.split('\n')) {
      ctx.active.host.showMessage('$ln\n', style: HostMessageStyle.dim);
    }
  } catch (e) {
    ctx.active.host.showMessage('$e\n', style: HostMessageStyle.error);
  }
}

Future<void> _new(CommandContext ctx) async {
  final open = ctx.openWorkflowEditor;
  if (open == null) {
    ctx.active.host.showMessage(
        '/workflow new needs the TUI editor.\n', style: HostMessageStyle.warning);
    return;
  }
  await open(isNew: true);
}

Future<void> _edit(CommandContext ctx, List<String> parts) async {
  final open = ctx.openWorkflowEditor;
  if (open == null) {
    ctx.active.host.showMessage(
        '/workflow edit needs the TUI editor.\n', style: HostMessageStyle.warning);
    return;
  }
  if (parts.length < 3) {
    ctx.active.host.showMessage('usage: /workflow edit <name>\n',
        style: HostMessageStyle.warning);
    return;
  }
  if (!_checkName(ctx, parts[2])) return;
  await open(name: parts[2], isNew: false);
}

/// A typed workflow name must be a bare name — `/workflow show ../x` must be
/// a usage error, not a file outside the workflows dir.
bool _checkName(CommandContext ctx, String name) {
  if (isSafeWorkflowName(name)) return true;
  ctx.active.host
      .showMessage('$nameRejection: "$name"\n', style: HostMessageStyle.error);
  return false;
}

/// Ensure the workflows directory exists (created lazily on first use). Returns
/// the directory, or null if [parent] is null.
Directory? ensureWorkflowsDir(Directory? parent) {
  if (parent == null) return null;
  if (!parent.existsSync()) parent.createSync(recursive: true);
  return parent;
}
