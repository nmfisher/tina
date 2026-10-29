/// The tool face: `web_search`, a query in, formatted hits out.
///
/// The tool owns input validation and rendering — nothing else. Whether
/// the call may touch the network is the authorization callback's
/// decision, asked per call with the backend's concrete host; a refusal
/// is an ordinary error result the model reads, never an exception.
/// The plugin is the reader, the tool is its model-facing face (the
/// `read_resource` shape), so the executor body lives on the plugin and
/// this class carries the schema and the two-line validation.
library;

import 'package:tina_core/tina_core.dart';

final class WebSearchTool {
  WebSearchTool._();

  /// The tool name, as the schema and the executor registry key. The old
  /// engine's name, kept.
  static const String schemaName = 'web_search';

  /// The hard ceiling on hits per call, whatever the schema allows: a
  /// result list is context the model reads whole.
  static const int maxCount = 20;

  /// The schema the plugin advertises for the turn.
  static ToolSchema schema() => ToolSchema(
        describe: (input) => ToolDescription(
            title: 'Web search', target: '${input['query'] ?? ''}'),
        name: schemaName,
        description: 'Search the web and return titles, URLs and short '
            'summaries. Use for current events, documentation lookups and '
            'anything outside the workspace. Follow a result by fetching '
            'its URL when the summary is not enough. Each search asks the '
            'session\'s permissions before it runs; a refusal arrives as '
            'this call\'s error result.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'The search query. Plain keywords work; '
                  'no operators are interpreted.',
            },
            'count': {
              'type': 'integer',
              'description':
                  'Maximum results to return, 1-$maxCount. Default 5.',
            },
          },
          'required': ['query'],
        },
      );
}
