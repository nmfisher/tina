import 'package:logging/logging.dart';

import 'tool.dart';

final _log = Logger('tina.tools.web_search');

/// One result a [SearchProvider] returns. Deliberately minimal — just what the
/// model needs to cite and follow up.
class SearchResult {
  final String url;
  final String title;
  final String snippet;

  const SearchResult({
    required this.url,
    required this.title,
    required this.snippet,
  });
}

/// A backend-agnostic web search. Implement this for a concrete index
/// (Brave, Tavily, Serper, …); swap implementations without touching the
/// [WebSearchTool] that wraps one.
abstract class SearchProvider {
  /// Returns up to [count] results for [query]. Throws [SearchError] on a
  /// transport or auth failure so the tool can surface it as an error result.
  ///
  /// [count] is the maximum number of results requested; providers clamp it to
  /// their own ceiling. Defaults to 5 when omitted.
  Future<List<SearchResult>> search(String query, {int count = 5});
}

/// Thrown by [SearchProvider] implementations when the request itself fails
/// (network, 401/403 key rejection, malformed response). The wrapped
/// [message] is user-facing; [statusCode] is present for HTTP-layer errors.
class SearchError implements Exception {
  final String message;
  final int? statusCode;
  const SearchError(this.message, {this.statusCode});

  @override
  String toString() => statusCode != null
      ? 'SearchError($statusCode): $message'
      : 'SearchError: $message';
}

/// Search the web and return snippets + URLs the model can cite. An
/// agent-invoked tool — the model calls it mid-turn when it needs live info
/// it can't get from training data or the local code graph (`search`).
///
/// Provider-pluggable: the tool just wraps a [SearchProvider]. The tool is only
/// registered in the agent's registry when a search API key is configured, so
/// the model never even sees it unless the user has opted in.
class WebSearchTool implements Tool {
  final SearchProvider provider;
  final int defaultCount;
  final int maxCount;

  WebSearchTool(
    this.provider, {
    this.defaultCount = 5,
    this.maxCount = 10,
  });

  @override
  ToolSchema get schema => const ToolSchema(
        name: 'web_search',
        description:
            'Search the web for current information the model may not know '
            '(recent events, docs, live data). Returns a list of results with '
            'a title, URL, and snippet for each. Use when the answer depends '
            'on information newer than the model\'s training cut-off, or when '
            'a user explicitly asks to look something up online.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'query': {
              'type': 'string',
              'description': 'The search query.',
            },
            'count': {
              'type': 'integer',
              'description':
                  'Number of results to return (1-10). Defaults to 5.',
            },
          },
          'required': ['query'],
        },
      );

  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    final query = input['query'] as String?;
    if (query == null || query.trim().isEmpty) {
      return ToolResult.error('query is required');
    }

    final requested = input['count'] as int? ?? defaultCount;
    final count = requested.clamp(1, maxCount);

    List<SearchResult> results;
    try {
      results = await provider.search(query.trim(), count: count);
    } on SearchError catch (e) {
      _log.warning('web_search failed: $e');
      return ToolResult.error('web_search failed: ${e.message}');
    } catch (e, st) {
      _log.warning('web_search unexpected error', e, st);
      return ToolResult.error('web_search failed: $e');
    }

    if (results.isEmpty) {
      return ToolResult('No results found for "$query".');
    }

    final out = StringBuffer();
    out.writeln('Results for "${query.trim()}":');
    for (var i = 0; i < results.length; i++) {
      final r = results[i];
      out.writeln();
      out.writeln('${i + 1}. ${r.title}');
      out.writeln('   ${r.url}');
      if (r.snippet.isNotEmpty) out.writeln('   ${r.snippet}');
    }
    final text = out.toString();
    return text.length <= 8000
        ? ToolResult(text)
        : ToolResult(text.substring(0, 8000) + '\n\n... (truncated)');
  }
}
