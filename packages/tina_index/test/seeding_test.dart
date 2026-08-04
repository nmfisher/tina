import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:test/test.dart';

import 'package:tina_index/seeding.dart';
import 'package:tina_index/store.dart';
import 'package:tina_index/symbol_table.dart';

String get repoRoot => p.normalize(p.join(Directory.current.path, '..', '..'));

void main() {
  group('seedQuery', () {
    late SymbolTable symbols;

    setUpAll(() {
      final graph = GraphStore.rebuildFromRepo(repoRoot);
      symbols = graph.symbols;
    });

    test('"stream" returns streaming-related symbols', () {
      final results = seedQuery(symbols, 'stream');
      expect(results, isNotEmpty);
      // ProviderStreamConsumer should rank high.
      expect(
        results.any((r) => r.contains('StreamConsumer')),
        isTrue,
        reason: 'Expected StreamConsumer in results: $results',
      );
    });

    test('"LlmProvider" returns LlmProvider as top result', () {
      final results = seedQuery(symbols, 'LlmProvider');
      expect(results, isNotEmpty);
      expect(results.first, contains('LlmProvider'));
    });

    test('"agent/agent.dart" returns symbols from that file', () {
      final results = seedQuery(symbols, 'agent/agent');
      expect(results, isNotEmpty);
      expect(results.any((r) => r.contains('Agent')), isTrue);
    });

    test('"xyzzy-nothing" returns empty list', () {
      final results = seedQuery(symbols, 'xyzzy-nothing');
      expect(results, isEmpty);
    });

    test('results are capped at maxResults', () {
      final results = seedQuery(symbols, 'a', maxResults: 3);
      expect(results.length, lessThanOrEqualTo(3));
    });

    test('empty query returns empty list', () {
      final results = seedQuery(symbols, '');
      expect(results, isEmpty);
    });
  });
}
