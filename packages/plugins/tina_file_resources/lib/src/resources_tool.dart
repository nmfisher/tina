/// The one tool: a name in, a body out.
///
/// Schema name `read_resource`, one required `name` string. The executor
/// delegates to [FileResourcesPlugin.fetch] — the plugin is the reader,
/// the tool is its model-facing face, so unknown names and a missing
/// directory come back as named errors, and a body is never returned
/// for a name the listing does not carry.
library;

import 'package:tina_core/tina_core.dart';
import 'package:tina_tools/tina_tools.dart' show Tool;

import 'plugin.dart';

final class ResourcesTool extends Tool {
  ResourcesTool(this._plugin);

  final FileResourcesPlugin _plugin;

  /// The tool name, as the schema and the executor registry key.
  static const String schemaName = 'read_resource';

  @override
  ToolSchema get schema => ToolSchema(
        describe: (input) => ToolDescription(
            title: 'Read resource', target: '${input['name'] ?? ''}'),
        name: schemaName,
        description: 'Read one resource body by its exact name, as '
            'listed in the prompt. Prefer this over reading the folder '
            'yourself: the listing is capped, the body is not.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'name': {
              'type': 'string',
              'description': 'The exact name from the listing.',
            },
          },
          'required': ['name'],
        },
      );

  @override
  Future<ToolResult> execute(Map<String, dynamic> input) {
    final name = input['name'];
    if (name is! String || name.trim().isEmpty) {
      return Future.value(
          ToolResult.error('$schemaName needs a non-empty "name" string'));
    }
    return _plugin.fetch(name);
  }
}
