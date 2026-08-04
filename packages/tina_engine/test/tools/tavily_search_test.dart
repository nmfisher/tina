import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:test/test.dart';

import 'package:tina_engine/tina_engine.dart';

/// Records the outgoing request, returns a scripted body + status. Lets a test
/// assert both the wire request (method, headers, body) and the parsed result.
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
  "answer": "A precomputed answer that the tool should ignore.",
  "results": [
    {
      "title": "Example",
      "url": "https://example.com",
      "content": "An example page."
    },
    {
      "title": "Second",
      "url": "https://second.com",
      "content": "Another example."
    }
  ]
}
''';

void main() {
  group('TavilySearchProvider request', () {
    test('POSTs with a bearer header and a JSON body of {query, max_results}',
        () async {
      final client = RecordingClient(body: '{"results": []}');
      final provider = TavilySearchProvider('test-key', client: client);

      await provider.search('hello world', count: 3);

      expect(client.requests, hasLength(1));
      final req = client.requests.single;
      expect(req.method, 'POST');
      expect(req.url.path, endsWith('/search'));
      expect(req.headers['authorization'], 'Bearer test-key');
      expect(req.headers['content-type'], 'application/json');
      expect(req.headers['accept'], 'application/json');

      final sent =
          jsonDecode((req as http.Request).body) as Map<String, dynamic>;
      expect(sent['query'], 'hello world');
      expect(sent['max_results'], 3);
    });

    test('clamps count into 1..20 before sending max_results', () async {
      final client = RecordingClient(body: '{"results": []}');
      final provider = TavilySearchProvider('k', client: client);

      await provider.search('q', count: 0);
      var sent = jsonDecode(
          (client.requests.last as http.Request).body);
      expect(sent['max_results'], 1);

      await provider.search('q', count: 99);
      sent = jsonDecode(
          (client.requests.last as http.Request).body);
      expect(sent['max_results'], 20);
    });

    test('allows overriding the base URL', () async {
      final client = RecordingClient(body: '{"results": []}');
      final provider = TavilySearchProvider(
        'k',
        baseUrl: 'https://localhost:8080',
        client: client,
      );
      await provider.search('q');
      expect(client.requests.single.url.host, 'localhost');
    });
  });

  group('TavilySearchProvider parsing', () {
    test('parses title/url/content and ignores the top-level answer',
        () async {
      final client = RecordingClient(body: _sampleResponse);
      final provider = TavilySearchProvider('k', client: client);

      final results = await provider.search('q', count: 5);

      expect(results, hasLength(2));
      expect(results[0].title, 'Example');
      expect(results[0].url, 'https://example.com');
      expect(results[0].snippet, 'An example page.');
      expect(results[1].title, 'Second');
      expect(results[1].snippet, 'Another example.');
    });

    test('returns an empty list when the body has no results', () async {
      final client = RecordingClient(body: '{"answer": "still empty"}');
      final provider = TavilySearchProvider('k', client: client);
      expect(await provider.search('q'), isEmpty);
    });
  });

  group('TavilySearchProvider errors', () {
    test('401 maps to a SearchError mentioning the API key', () async {
      final client = RecordingClient(body: '{}', status: 401);
      final provider = TavilySearchProvider('bad-key', client: client);

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
      final client = RecordingClient(
          body: '{"error": {"message": "rate limited"}}', status: 429);
      final provider = TavilySearchProvider('k', client: client);

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
