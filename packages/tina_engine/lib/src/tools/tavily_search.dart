import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../llm/http.dart';
import 'web_search.dart';

final _log = Logger('tina.tools.tavily');

/// [SearchProvider] backed by the [Tavily Search
/// API](https://docs.tavily.com). OpenAI-agnostic: transparent raw snippets
/// and URLs (no opaque encrypted blobs), bill-gated by the user's own Tavily
/// key.
///
/// Auth uses `Authorization: Bearer`. The request is a JSON POST, unlike
/// Brave's GET + query params, but the [SearchProvider] surface is identical —
/// swap implementations without touching the [WebSearchTool] that wraps one.
class TavilySearchProvider implements SearchProvider {
  static const _defaultBaseUrl = 'https://api.tavily.com';
  static const _userAgent = 'tina/1.0';

  /// Tavily caps `max_results` at 20; the tool clamps into 1..this.
  static const int maxResults = 20;

  final http.Client _client;
  final String _apiKey;
  final String _baseUrl;

  /// [apiKey] is the user's Tavily API key. [baseUrl] is overridable for tests
  /// / proxies; [_client] is injectable so tests can stub transport.
  TavilySearchProvider(
    this._apiKey, {
    String baseUrl = _defaultBaseUrl,
    http.Client? client,
  })  : _baseUrl = baseUrl,
        _client = client ?? http.Client();

  @override
  Future<List<SearchResult>> search(String query, {int count = 5}) async {
    final clamped = count.clamp(1, maxResults);
    final uri = Uri.parse('$_baseUrl/search');

    // `sendWithRetry` (shared transport in lib/llm/http.dart) needs a fresh
    // Request per attempt.
    http.Request build() {
      final r = http.Request('POST', uri);
      r.headers.addAll({
        'Authorization': 'Bearer $_apiKey',
        'Accept': 'application/json',
        'Content-Type': 'application/json',
        'User-Agent': _userAgent,
      });
      r.body = jsonEncode({
        'query': query,
        'max_results': clamped,
      });
      return r;
    }

    final resp = await sendWithRetry(_client, build);
    final body = await resp.stream.bytesToString();

    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw SearchError(
        'Tavily rejected the API key (check TAVILY_API_KEY).',
        statusCode: resp.statusCode,
      );
    }
    if (resp.statusCode != 200) {
      throw SearchError(
        humanizeHttpError('Tavily', resp.statusCode, body),
        statusCode: resp.statusCode,
      );
    }

    return _parse(body);
  }

  /// Decodes the response body into results. Extracted so tests can exercise
  /// parsing without any network.
  static List<SearchResult> _parse(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map) {
      _log.fine('Tavily response is not a JSON object');
      return const [];
    }
    final results = decoded['results'];
    if (results is! List) return const [];

    final out = <SearchResult>[];
    for (final raw in results) {
      if (raw is! Map) continue;
      final url = raw['url'];
      final title = raw['title'];
      final snippet = raw['content'];
      if (url is! String || url.isEmpty) continue;
      out.add(SearchResult(
        url: url,
        title: title is String ? title : url,
        snippet: snippet is String ? snippet : '',
      ));
    }
    return out;
  }

  /// Visible for tests: close the underlying client. Production creates a
  /// fresh client per call and relies on garbage collection.
  // ignore: unused_element
  void _close() => _client.close();
}
