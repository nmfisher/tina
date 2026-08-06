import 'dart:io';

import 'package:tina_engine/tina_engine.dart';

import '../session_commands/command_context.dart';
import 'pipeline_runner.dart';

/// The `/workflow` slash command: `list`, `show <name>`, `run <name> [input]`.
/// Dispatched from [SessionCommandHandlers]. List/show read directly from
/// [CommandContext.workflowsDir]; run delegates to the coordinator-wired
/// [CommandContext.runWorkflow].
Future<void> handleWorkflowCommand(CommandContext ctx, String line) async {
  final parts = line.split(RegExp(r'\s+'));
  final sub = parts.length < 2 ? 'list' : parts[1];

  switch (sub) {
    case 'list':
      await _list(ctx);
    case 'show':
      await _show(ctx, parts);
    case 'run':
      await _run(ctx, parts);
    default:
      ctx.active.host.showMessage(
          'usage: /workflow [list | show <name> | run <name> [input...]]\n',
          style: HostMessageStyle.warning);
  }
}

Future<void> _list(CommandContext ctx) async {
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
    return;
  }
  ctx.active.host.showMessage('workflows:\n');
  for (final n in names) {
    ctx.active.host.showMessage('  $n\n', style: HostMessageStyle.dim);
  }
}

Future<void> _show(CommandContext ctx, List<String> parts) async {
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
  final name = parts[2];
  try {
    final source = await PipelineRunner.readWorkflow(dir, name);
    ctx.active.host.showSeparator();
    for (final ln in source.split('\n')) {
      ctx.active.host.showMessage('$ln\n', style: HostMessageStyle.dim);
    }
  } catch (e) {
    ctx.active.host.showMessage('$e\n', style: HostMessageStyle.error);
  }
}

Future<void> _run(CommandContext ctx, List<String> parts) async {
  final run = ctx.runWorkflow;
  if (run == null) {
    ctx.active.host.showMessage(
        '/workflow run needs the pipeline runner (TUI or --workflow)\n',
        style: HostMessageStyle.warning);
    return;
  }
  if (parts.length < 3) {
    ctx.active.host.showMessage('usage: /workflow run <name> [input...]\n',
        style: HostMessageStyle.warning);
    return;
  }
  final name = parts[2];
  final input = parts.length > 3 ? parts.sublist(3).join(' ') : null;
  await run(workflowName: name, input: input);
}

/// Ensure the workflows directory exists (created lazily on first use). Returns
/// the directory, or null if [parent] is null.
Directory? ensureWorkflowsDir(Directory? parent) {
  if (parent == null) return null;
  if (!parent.existsSync()) parent.createSync(recursive: true);
  return parent;
}
