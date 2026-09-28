/// The one tool: a prompt in, the child's final text out.
///
/// Schema name `spawn_subagent`, one required `prompt` string. The
/// executor delegates straight to [SubagentsPlugin.spawn] — the plugin
/// is the spawner, the tool is its model-facing face — so every limit is
/// enforced in exactly one place and refusals are normal tool results
/// naming the limit. Cancellation rides along: the plugin stashed the
/// turn's context in `beforeToolCall`, and the cancelled state travels
/// from that context to the child's loop.
library;

import 'package:tina_core/tina_core.dart';
import 'package:tina_tools/tina_tools.dart' show Tool;

import 'subagents_plugin.dart';

final class SpawnTool extends Tool {
  SpawnTool(this._plugin);

  final SubagentsPlugin _plugin;

  @override
  ToolSchema get schema => ToolSchema(
        name: SubagentsPlugin.schemaName,
        description: 'Spawn one sub-agent to do a scoped piece of work. '
            'Give it a self-contained prompt; its final text is returned '
            'as this tool\'s result. Refused when the depth, concurrency '
            'or token-budget limit is hit.',
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
  Future<ToolResult> execute(Map<String, dynamic> input) {
    final prompt = input['prompt'];
    if (prompt is! String || prompt.trim().isEmpty) {
      return Future.value(
          ToolResult.error('spawn_subagent needs a non-empty "prompt" string'));
    }
    return _plugin.spawn(prompt, cancelled: () => _plugin.turnCancelled);
  }
}
