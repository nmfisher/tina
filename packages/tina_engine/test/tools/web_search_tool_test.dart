import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

/// A scriptable [SearchProvider] for tests: returns a fixed result list, throws
/// a [SearchError], or records the query/count it was asked for.
class FakeSearchProvider implements SearchProvider {
  List<SearchResult> results;
  SearchError? error;
  String? lastQuery;
  int? lastCount;

  FakeSearchProvider({
    this.results = const [],
    this.error,
  });

  @override
  Future<List<SearchResult>> search(String query, {int count = 5}) async {
    lastQuery = query;
    lastCount = count;
    if (error != null) throw error!;
    return results;
  }
}

void main() {
  group('WebSearchTool schema', () {
    test('name is web_search and query is required', () {
      final tool = WebSearchTool(FakeSearchProvider());
      expect(tool.schema.name, 'web_search');
      expect(tool.schema.inputSchema['required'], contains('query'));
      final props =
          tool.schema.inputSchema['properties'] as Map<String, dynamic>;
      expect(props.keys, containsAll(['query', 'count']));
    });
  });

  group('WebSearchTool execute', () {
    test('formats results with title, url, and snippet', () async {
      final provider = FakeSearchProvider(results: const [
        SearchResult(
          url: 'https://example.com/a',
          title: 'Page A',
          snippet: 'Snippet about A.',
        ),
        SearchResult(
          url: 'https://example.com/b',
          title: 'Page B',
          snippet: '',
        ),
      ]);
      final tool = WebSearchTool(provider);
      final r = await tool.execute({'query': 'hello world'});

      expect(r.isError, isFalse);
      expect(provider.lastQuery, 'hello world');
      expect(r.content, contains('Results for "hello world"'));
      expect(r.content, contains('1. Page A'));
      expect(r.content, contains('https://example.com/a'));
      expect(r.content, contains('Snippet about A.'));
      expect(r.content, contains('2. Page B'));
      expect(r.content, contains('https://example.com/b'));
    });

    test('reports a friendly message on no results', () async {
      final tool = WebSearchTool(FakeSearchProvider(results: const []));
      final r = await tool.execute({'query': 'obscure thing'});
      expect(r.isError, isFalse);
      expect(r.content, contains('No results found'));
    });

    test('surfaces provider SearchError as an error result', () async {
      final provider = FakeSearchProvider(
        error: const SearchError('Brave rejected the API key (check BRAVE_API_KEY).',
            statusCode: 401),
      );
      final tool = WebSearchTool(provider);
      final r = await tool.execute({'query': 'anything'});
      expect(r.isError, isTrue);
      expect(r.content, contains('web_search failed'));
      expect(r.content, contains('Brave rejected the API key'));
    });

    test('count is clamped into 1..maxCount', () async {
      final provider = FakeSearchProvider(
        results: const [SearchResult(url: 'u', title: 't', snippet: 's')],
      );
      final tool = WebSearchTool(provider, maxCount: 10);

      await tool.execute({'query': 'q', 'count': 0});
      expect(provider.lastCount, 1);

      await tool.execute({'query': 'q', 'count': 99});
      expect(provider.lastCount, 10);
    });

    test('missing/empty query is an error', () async {
      final tool = WebSearchTool(FakeSearchProvider());
      final r = await tool.execute({'query': '   '});
      expect(r.isError, isTrue);
      expect(r.content, contains('query is required'));
    });
  });
}
