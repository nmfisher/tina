/// The one shipped backend: the Brave Search API.
///
/// `GET /res/v1/web/search?q=…&count=…` with the key riding
/// `x-subscription-token`. The key arrives through a closure read at
/// call time — the descriptor rule: names and functions in source, values
/// from the environment at runtime, never in logs or errors. A missing
/// key fails that call with a clear message; it is not a crash and not a
/// silent empty result.
library;

import 'dart:async';
import 'dart:convert';

import 'package:tina_llm/tina_llm.dart';

import 'backend.dart';

final class BraveSearchBackend implements SearchBackend {
  BraveSearchBackend({
    required String Function() keyFrom,
    HttpEndpoint? endpoint,
  })  : _keyFrom = keyFrom,
        _endpoint = endpoint ?? IoHttpEndpoint(endpoint: 'https://api.search.brave.com');

  static const _searchPath = '/res/v1/web/search';

  final String Function() _keyFrom;
  final HttpEndpoint _endpoint;

  @override
  String get host => 'api.search.brave.com';

  @override
  Future<List<SearchHit>> search(String query, {required int count}) async {
    final key = _keyFrom();
    if (key.isEmpty) {
      throw const SearchException(
          'no search API key: set BRAVE_SEARCH_API_KEY in the environment');
    }
    final HttpResponse response;
    try {
      response = await _endpoint.get(
        '$_searchPath?q=${Uri.encodeQueryComponent(query)}&count=$count',
        headers: {
          'accept': 'application/json',
          'accept-encoding': 'gzip',
          'x-subscription-token': key,
        },
      );
    } catch (e) {
      throw SearchException('search request failed: transport error ($e)');
    }
    if (response.statusCode != 200) {
      final body = await _readBody(response);
      throw SearchException(
        body.isEmpty ? 'HTTP ${response.statusCode}' : body,
        statusCode: response.statusCode,
      );
    }
    final decoded = jsonDecode(await _readBody(response));
    if (decoded is! Map<String, dynamic>) {
      throw const SearchException('search response was not an object');
    }
    final web = decoded['web'];
    final results = web is Map<String, dynamic> ? web['results'] : null;
    if (results is! List) return const [];
    return [
      for (final row in results)
        if (row is Map<String, dynamic>)
          SearchHit(
            title: row['title'] is String ? row['title'] as String : '',
            url: row['url'] is String ? row['url'] as String : '',
            snippet: row['description'] is String
                ? row['description'] as String
                : '',
          ),
    ];
  }

  void close() {
    final e = _endpoint;
    if (e is IoHttpEndpoint) e.close();
  }

  static Future<String> _readBody(HttpResponse response) =>
      response.body
          .transform(utf8.decoder)
          .fold(StringBuffer(), (b, c) => b..write(c))
          .then((b) => b.toString());
}
