/// The plugin: one tool, one approval callback, no prompt section.
///
/// [WebSearchPlugin.authorize] is the whole permission story: the host
/// wires it to the session's approval flow (mode policy → human), and
/// the executor awaits it with the backend's concrete host before the
/// backend runs; a false returns the refusal as the call's error result.
/// Default-off at the host: the tool is useless without a backend key
/// anyway, so nothing is advertised that cannot run.
library;

import 'dart:async';

import 'package:tina_engine_2/tina_engine_2.dart';

import 'backend.dart';
import 'web_search_tool.dart';

final class WebSearchPlugin extends AgentPlugin {
  WebSearchPlugin({
    this.id = 'tina/web-search',
    this.order = 12,
    required SearchBackend backend,
    required Future<bool> Function(String host, String query) authorize,
    int defaultCount = 5,
  })  : _backend = backend,
        _authorize = authorize,
        _defaultCount = defaultCount;

  @override
  final String id;

  /// Just after the tools plugin (10); it is a tool carrier.
  @override
  final int order;

  final SearchBackend _backend;
  final Future<bool> Function(String host, String query) _authorize;
  final int _defaultCount;

  /// Clamp `count` into 1-[WebSearchTool.maxCount]. A bad model value
  /// (string, zero, huge) becomes the default rather than an error — the
  /// call still has a query to run.
  int countFor(Object? requested) {
    final n = requested is int ? requested : int.tryParse('$requested');
    if (n == null || n < 1) return _defaultCount;
    return n > WebSearchTool.maxCount ? WebSearchTool.maxCount : n;
  }

  /// The tool's executor body, exposed so the schema stays a thin face:
  /// validation → authorization → backend → rendered result.
  Future<ToolResult> search({
    Object? query,
    Object? count,
  }) async {
    if (query is! String || query.trim().isEmpty) {
      return ToolResult.error(
          '${WebSearchTool.schemaName} needs a non-empty "query" string');
    }
    final clamped = countFor(count);
    if (!await _authorize(_backend.host, query)) {
      return ToolResult.error(
          '${WebSearchTool.schemaName}: permission to search '
          '${_backend.host} was not granted');
    }
    final List<SearchHit> hits;
    try {
      hits = await _backend.search(query.trim(), count: clamped);
    } on SearchException catch (e) {
      return ToolResult.error('${WebSearchTool.schemaName}: ${e.message}');
    } catch (e) {
      return ToolResult.error(
          '${WebSearchTool.schemaName}: search failed ($e)');
    }
    if (hits.isEmpty) {
      return const ToolResult('No results.');
    }
    return ToolResult([
      for (var i = 0; i < hits.length; i++)
        '[${i + 1}] ${hits[i].title}\n'
            '${hits[i].url}\n'
            '${hits[i].snippet}',
    ].join('\n\n'));
  }

  @override
  List<ToolSchema> get tools => [WebSearchTool.schema()];

  @override
  void mountOn(AgentLoop loop) {
    // The full ToolResult, refusals included — a string-only wrapper
    // would flatten an authorization refusal into plain text and the
    // model would read a denial as search output.
    loop.registerExecutor(
        WebSearchTool.schemaName,
        (input) => search(
              query: input['query'],
              count: input['count'],
            ));
  }

  @override
  void closeSession() => _backend.close();
}
