import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'package:tina_engine/tina_engine.dart';

/// Records the outgoing request, returns a scripted body + status. Lets a test
/// assert both the wire request (headers, query params) and the parsed result.
class RecordingClient extends http.BaseClient {
  final List<http.BaseRequest> requests = [];
  String body;
  int status;

  RecordingClient({required this.body, this.status = 200});

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add(request);
    return http.StreamedResponse(
      Stream.value(utf8.encode(body)),
      status,
    );
  }
}

const _sampleResponse = '''
{
  "web": {
    "results": [
      {
        "title": "Example",
        "url": "https://example.com",
        "description": "An example page."
      },
      {
        "title": "Second",
        "url": "https://second.com",
        "snippet": "Uses the alternate snippet field."
      }
    ]
  }
}
''';

void main() {
  group('BraveSearchProvider request', () {
    test('sends q, count, and the subscription-token header', () async {
      final client = RecordingClient(body: '{"web": {"results": []}}');
      final provider = BraveSearchProvider('test-key', client: client);

      await provider.search('hello world', count: 3);

      expect(client.requests, hasLength(1));
      final req = client.requests.single;
      expect(req.url.queryParameters['q'], 'hello world');
      expect(req.url.queryParameters['count'], '3');
      expect(req.url.path, endsWith('/res/v1/web/search'));
      expect(req.headers['x-subscription-token'], 'test-key');
      expect(req.headers['accept'], 'application/json');
    });

    test('allows overriding the base URL', () async {
      final client = RecordingClient(body: '{"web": {"results": []}}');
      final provider = BraveSearchProvider(
        'k',
        baseUrl: 'https://localhost:8080',
        client: client,
      );
      await provider.search('q');
      expect(client.requests.single.url.host, 'localhost');
    });
  });

  group('BraveSearchProvider parsing', () {
    test('parses title/url/description and the alternate snippet field',
        () async {
      final client = RecordingClient(body: _sampleResponse);
      final provider = BraveSearchProvider('k', client: client);

      final results = await provider.search('q', count: 5);

      expect(results, hasLength(2));
      expect(results[0].title, 'Example');
      expect(results[0].url, 'https://example.com');
      expect(results[0].snippet, 'An example page.');
      expect(results[1].snippet, 'Uses the alternate snippet field.');
    });

    test('returns an empty list when the body has no web.results', () async {
      final client = RecordingClient(body: '{"query": "q"}');
      final provider = BraveSearchProvider('k', client: client);
      expect(await provider.search('q'), isEmpty);
    });
  });

  group('BraveSearchProvider errors', () {
    test('401 maps to a SearchError mentioning the API key', () async {
      final client = RecordingClient(body: '{}', status: 401);
      final provider = BraveSearchProvider('bad-key', client: client);

      expect(
        () => provider.search('q'),
        throwsA(isA<SearchError>().having(
          (e) => e.statusCode,
          'statusCode',
          401,
        )),
      );
    });

    test('other non-200 statuses map to a SearchError', () async {
      final client =
          RecordingClient(body: '{"error": {"message": "rate limited"}}', status: 429);
      final provider = BraveSearchProvider('k', client: client);

      expect(
        () => provider.search('q'),
        throwsA(isA<SearchError>().having(
          (e) => e.statusCode,
          'statusCode',
          429,
        )),
      );
    });
  });
}
