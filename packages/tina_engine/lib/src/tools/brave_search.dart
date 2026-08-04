import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

import '../llm/http.dart';
import 'web_search.dart';

final _log = Logger('tina.tools.brave');

/// [SearchProvider] backed by the [Brave Search
/// API](https://api.search.brave.com). OpenAI-agnostic: transparent raw
/// snippets and URLs (no opaque encrypted blobs), bill-gated by the user's own
/// Brave key.
///
/// Auth uses the `X-Subscription-Token` header, which Brave documents as the
/// preferred key header; `Authorization: Bearer` is accepted as a fallback.
class BraveSearchProvider implements SearchProvider {
  static const _defaultBaseUrl = 'https://api.search.brave.com';
  static const _userAgent = 'tina/1.0';

  final http.Client _client;
  final String _apiKey;
  final String _baseUrl;

  /// [apiKey] is the user's Brave Search API key. [baseUrl] is overridable for
  /// tests / proxies; [_client] is injectable so tests can stub transport.
  BraveSearchProvider(
    this._apiKey, {
    String baseUrl = _defaultBaseUrl,
    http.Client? client,
  })  : _baseUrl = baseUrl,
        _client = client ?? http.Client();

  @override
  Future<List<SearchResult>> search(String query, {int count = 5}) async {
    final uri = Uri.parse('$_baseUrl/res/v1/web/search').replace(
      queryParameters: {
        'q': query,
        'count': '$count',
      },
    );

    // `sendWithRetry` (shared transport in lib/llm/http.dart) needs a fresh
    // Request per attempt.
    http.Request build() {
      final r = http.Request('GET', uri);
      r.headers.addAll({
        'Accept': 'application/json',
        'Accept-Encoding': 'gzip',
        'X-Subscription-Token': _apiKey,
        'User-Agent': _userAgent,
      });
      return r;
    }

    final resp = await sendWithRetry(_client, build);
    final body = await resp.stream.bytesToString();

    if (resp.statusCode == 401 || resp.statusCode == 403) {
      throw SearchError(
        'Brave rejected the API key (check BRAVE_API_KEY).',
        statusCode: resp.statusCode,
      );
    }
    if (resp.statusCode != 200) {
      throw SearchError(
        humanizeHttpError('Brave', resp.statusCode, body),
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
      _log.fine('Brave response is not a JSON object');
      return const [];
    }
    final web = decoded['web'];
    if (web is! Map) return const [];
    final results = web['results'];
    if (results is! List) return const [];

    final out = <SearchResult>[];
    for (final raw in results) {
      if (raw is! Map) continue;
      final url = raw['url'];
      final title = raw['title'];
      final snippet = raw['description'] ?? raw['snippet'];
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
