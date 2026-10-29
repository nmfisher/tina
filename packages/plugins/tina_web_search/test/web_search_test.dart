// The whole plugin, headless: validation, clamping, authorization,
// rendering and the Brave wire format, with a fake backend and recorded
// HTTP bytes through the injected endpoint. No network, no credentials —
// the key in tests is a literal handed to the injected closure.
library;

import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_llm/tina_llm.dart';
import 'package:tina_web_search/tina_web_search.dart';

/// A backend that remembers queries and returns canned hits.
final class FakeBackend extends SearchBackend {
  FakeBackend({this.host = 'search.example.invalid', this.hits = const []});
  final String host;
  final List<SearchHit> hits;
  final queries = <String>[];
  int? lastCount;

  @override
  Future<List<SearchHit>> search(String query, {required int count}) async {
    queries.add(query);
    lastCount = count;
    return hits;
  }
}

/// A fake Brave response body: status and envelope exactly as the API
/// documents them, so the parser is pinned to the wire, not the fake.
HttpResponse braveResponse(int status, {List<dynamic>? results}) =>
    HttpResponse(
      statusCode: status,
      headers: const {'content-type': 'application/json'},
      body: Stream.fromIterable([
        utf8.encode(jsonEncode({
          if (results != null)
            'web': {
              'results': [
                for (final r in results)
                  {
                    'title': r,
                    'url': 'https://example.invalid/$r',
                    'description': 'The summary of $r.',
                  }
              ],
            }
        })),
      ]),
    );

/// Records the request path and headers; replays [response].
final class RecordingEndpoint implements HttpEndpoint {
  RecordingEndpoint(this.response);
  final HttpResponse response;
  String? path;
  Map<String, String>? headers;

  @override
  Future<HttpResponse> get(String path,
      {Map<String, String> headers = const {}}) async {
    this.path = path;
    this.headers = headers;
    return response;
  }

  @override
  Future<HttpResponse> post(String path,
          {required Map<String, String> headers, required List<int> body}) =>
      throw UnimplementedError();
}

void main() {
  group('input and clamping', () {
    test('an empty or non-string query is a named error, not a crash',
        () async {
      final plugin = WebSearchPlugin(
          backend: FakeBackend(), authorize: (_, __) async => true);
      for (final bad in [null, '', '   ', 42]) {
        final result = await plugin.search(query: bad);
        expect(result.isError, isTrue, reason: 'query=$bad');
        expect(result.content, contains('needs a non-empty "query" string'));
      }
    });

    test('count clamps into 1–20; junk falls back to the default', () {
      final plugin = WebSearchPlugin(
          backend: FakeBackend(),
          authorize: (_, __) async => true,
          defaultCount: 5);
      expect(plugin.countFor(null), 5);
      expect(plugin.countFor('junk'), 5);
      expect(plugin.countFor(0), 5);
      expect(plugin.countFor(-3), 5);
      expect(plugin.countFor(1), 1);
      expect(plugin.countFor(20), 20);
      expect(plugin.countFor(500), 20);
    });
  });

  group('authorization', () {
    test('the backend host is what gets asked, before the backend runs',
        () async {
      final backend = FakeBackend();
      final asked = <String>[];
      final plugin = WebSearchPlugin(
          backend: backend,
          authorize: (host, query) async {
            asked.add('$host|$query');
            return false;
          });
      final result = await plugin.search(query: 'dart records');
      expect(asked, ['search.example.invalid|dart records']);
      expect(result.isError, isTrue);
      expect(result.content, contains('permission to search'));
      // Refused: the backend never saw the query.
      expect(backend.queries, isEmpty);
    });

    test('an approved call reaches the backend and renders the hits',
        () async {
      final backend = FakeBackend(hits: [
        const SearchHit(
            title: 'Records',
            url: 'https://dart.dev/language/records',
            snippet: 'Records are immutable aggregates.'),
      ]);
      final plugin = WebSearchPlugin(
          backend: backend, authorize: (_, __) async => true);
      final result = await plugin.search(query: 'dart records', count: 3);
      expect(result.isError, isFalse);
      expect(backend.queries, ['dart records']);
      expect(backend.lastCount, 3);
      expect(result.content, contains('[1] Records'));
      expect(result.content, contains('https://dart.dev/language/records'));
      expect(result.content, contains('Records are immutable aggregates.'));
    });

    test('zero hits are a clean result, not an error', () async {
      final plugin = WebSearchPlugin(
          backend: FakeBackend(), authorize: (_, __) async => true);
      final result = await plugin.search(query: 'nothing to find');
      expect(result.isError, isFalse);
      expect(result.content, 'No results.');
    });

    test('a backend failure is an ordinary error result', () async {
      final plugin = WebSearchPlugin(
          backend: FailingBackend(),
          authorize: (_, __) async => true);
      final result = await plugin.search(query: 'q');
      expect(result.isError, isTrue);
      expect(result.content, contains('boom'));
    });
  });

  group('the brave backend', () {
    test('query and count ride the request; the key rides its header',
        () async {
      final endpoint = RecordingEndpoint(braveResponse(200, results: ['a']));
      final backend = BraveSearchBackend(
          keyFrom: () => 'fixture-key', endpoint: endpoint);
      addTearDown(backend.close);
      final hits = await backend.search('dart 3 records', count: 7);
      expect(endpoint.path,
          '/res/v1/web/search?q=dart+3+records&count=7');
      expect(endpoint.headers!['x-subscription-token'], 'fixture-key');
      expect(hits, hasLength(1));
      expect(hits.single.title, 'a');
      expect(hits.single.url, 'https://example.invalid/a');
      expect(hits.single.snippet, 'The summary of a.');
    });

    test('a missing key fails that call with a clear message', () async {
      final endpoint = RecordingEndpoint(braveResponse(200, results: ['a']));
      final backend =
          BraveSearchBackend(keyFrom: () => '', endpoint: endpoint);
      addTearDown(backend.close);
      expect(() => backend.search('q', count: 5),
          throwsA(isA<SearchException>()));
      // Nothing was sent.
      expect(endpoint.path, isNull);
    });

    test('a non-200 surfaces the service message with its status', () async {
      final endpoint = RecordingEndpoint(HttpResponse(
        statusCode: 429,
        headers: const {},
        body: Stream.fromIterable([utf8.encode('rate limited')]),
      ));
      final backend = BraveSearchBackend(
          keyFrom: () => 'fixture-key', endpoint: endpoint);
      addTearDown(backend.close);
      try {
        await backend.search('q', count: 5);
        fail('expected SearchException');
      } on SearchException catch (e) {
        expect(e.statusCode, 429);
        expect(e.toString(), contains('rate limited'));
      }
    });

    test('a body without results is zero hits, not an error', () async {
      final endpoint =
          RecordingEndpoint(braveResponse(200) /* no `web` at all */);
      final backend = BraveSearchBackend(
          keyFrom: () => 'fixture-key', endpoint: endpoint);
      addTearDown(backend.close);
      expect(await backend.search('q', count: 5), isEmpty);
    });

    test('the host is the concrete API origin, for the approval prompt',
        () {
      final backend =
          BraveSearchBackend(keyFrom: () => 'fixture-key');
      addTearDown(backend.close);
      expect(backend.host, 'api.search.brave.com');
    });
  });

  group('the plugin face', () {
    test('the tool schema is named web_search and requires a query', () {
      final plugin = WebSearchPlugin(
          backend: FakeBackend(), authorize: (_, __) async => true);
      final schema = plugin.tools.single;
      expect(schema.name, 'web_search');
      expect(schema.inputSchema['required'], ['query']);
    });

    test(
        'mountOn registers the executor; the mounted loop runs a full turn '
        'end to end, refusal and all', () async {
      final plugin = WebSearchPlugin(
          backend: FakeBackend(hits: [
            const SearchHit(title: 't', url: 'https://u.invalid', snippet: 's')
          ]),
          authorize: (_, __) async => true);
      final loop = AgentLoop(
          provider: ScriptedProvider([
            scriptedReply('', calls: [
              const ToolUseBlock(
                  id: 'c1', name: 'web_search', input: {'query': 'q'})
            ]),
            scriptedReply('done'),
          ]),
          plugins: [plugin]);
      loop.mountPlugin(plugin);
      final outcome = await loop.runTurn(const Input('search for q', id: 'i1'));
      expect(outcome.stopReason, StopReason.complete);
      final resultBlock = outcome.messages
          .expand((m) => m.content.whereType<ToolResultBlock>())
          .single;
      expect(resultBlock.isError, isFalse);
      expect(resultBlock.content, contains('[1] t'));
    });

    test('a refusal reaches the model as an error-flagged tool result',
        () async {
      final backend = FakeBackend();
      final plugin = WebSearchPlugin(
          backend: backend, authorize: (_, __) async => false);
      final loop = AgentLoop(
          provider: ScriptedProvider([
            scriptedReply('', calls: [
              const ToolUseBlock(
                  id: 'c1', name: 'web_search', input: {'query': 'q'})
            ]),
            scriptedReply('understood'),
          ]),
          plugins: [plugin]);
      loop.mountPlugin(plugin);
      final outcome = await loop.runTurn(const Input('search', id: 'i2'));
      final resultBlock = outcome.messages
          .expand((m) => m.content.whereType<ToolResultBlock>())
          .single;
      expect(resultBlock.isError, isTrue);
      expect(resultBlock.content, contains('permission to search'));
      expect(backend.queries, isEmpty);
    });
  });
}

final class FailingBackend extends SearchBackend {
  @override
  String get host => 'failing.example.invalid';
  @override
  Future<List<SearchHit>> search(String query, {required int count}) =>
      throw const SearchException('boom');
}
