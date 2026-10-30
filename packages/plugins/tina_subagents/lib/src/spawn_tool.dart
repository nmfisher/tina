/// The two model-facing tools of the sub-agents plugin.
///
/// `launch_subagent` takes a self-contained prompt, launches a child in
/// the background, and returns immediately with the child's id — it does
/// NOT block the parent. The `subagent` companion tool inspects a
/// launched child: `status` reports progress (and the final answer once
/// settled), `wait` blocks until the child settles and returns its final
/// text, and `cancel` stops it.
///
/// Both executors delegate straight to [SubagentsPlugin] — the plugin is
/// the backend, the tools are its model-facing faces — so every limit is
/// enforced in exactly one place and refusals are normal tool results
/// naming the limit.
library;

import 'package:tina_core/tina_core.dart';
import 'package:tina_tools/tina_tools.dart' show Tool;

import 'subagents_plugin.dart';

final class LaunchSubagentTool extends Tool {
  LaunchSubagentTool(this._plugin);

  final SubagentsPlugin _plugin;

  @override
  ToolSchema get schema => ToolSchema(
        describe: (input) => ToolDescription(
            title: 'Launch subagent', target: '${input['prompt'] ?? ''}'),
        name: SubagentsPlugin.launchSchemaName,
        description: 'Launch a sub-agent to do a scoped piece of work: '
            'research, a scoped implementation, an analysis, an '
            'independent check — anything self-contained that would '
            'otherwise fill this conversation with intermediate steps. '
            'The sub-agent works in its own context and does not return '
            'intermediate steps; you receive its result as a message '
            'when it finishes. The tool returns immediately with the '
            'sub-agent\'s id, and the sub-agent runs in the background '
            'while you keep working. Launch several independent '
            'delegations in one message. `subagent` can still retrieve '
            'a settled result. Refused when the depth, concurrency or '
            'token-budget limit is hit.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'prompt': {
              'type': 'string',
              'description': 'The complete task for the sub-agent. It '
                  'cannot ask you questions; the prompt must stand alone.',
            },
          },
          'required': ['prompt'],
        },
      );

  @override
  Future<ToolResult> execute(Map<String, dynamic> input,
      {void Function(String)? progress}) {
    final prompt = input['prompt'];
    if (prompt is! String || prompt.trim().isEmpty) {
      return Future.value(ToolResult.error(
          'launch_subagent needs a non-empty "prompt" string'));
    }
    return Future.value(_plugin.launch(prompt));
  }
}

final class SubagentInspectTool extends Tool {
  SubagentInspectTool(this._plugin);

  final SubagentsPlugin _plugin;

  @override
  ToolSchema get schema => ToolSchema(
        describe: (input) => ToolDescription(
            title: 'Subagent status', target: '${input['id'] ?? ''}'),
        name: SubagentsPlugin.inspectSchemaName,
        description:
            'Inspect, wait for, or cancel a launched sub-agent. You are '
            'told when a sub-agent finishes — its answer arrives as a '
            'message — so do not poll a running one: use `status` once '
            'to re-read a settled result, `wait` only when genuinely '
            'blocked on it, `cancel` to stop it.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'id': {'type': 'string'},
            'action': {
              'type': 'string',
              'enum': ['status', 'wait', 'cancel']
            },
            'wait_ms': {'type': 'integer', 'minimum': 0},
          },
          'required': ['id'],
        },
      );

  @override
  Future<ToolResult> execute(Map<String, dynamic> input,
      {void Function(String)? progress}) {
    final id = input['id'];
    if (id is! String || id.trim().isEmpty) {
      return Future.value(ToolResult.error('subagent needs an "id" string'));
    }
    final action = (input['action'] as String?) ?? 'status';
    final waitMs = (input['wait_ms'] as num?)?.toInt();
    return _plugin.inspect(id,
        action: action, waitMs: waitMs, progress: progress);
  }
}
