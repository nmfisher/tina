import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:test/test.dart';

import 'package:tina_index/seeding.dart';
import 'package:tina_index/store.dart';
import 'package:tina_index/symbol.dart';
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

    test('one slot per bare symbol name, however many bearers (#39)', () {
      // Regression for the live-tree failure: seven classes declaring
      // streamIdleTimeout took seven of ten slots and evicted
      // ProviderStreamConsumer. A synthetic table pins the behavior
      // without depending on the repo's current shape.
      Symbol sym(String name, String path, {String? parent}) => Symbol(
            name: name,
            kind: SymbolKind.field,
            filePath: path,
            lineStart: 1,
            lineEnd: 2,
            parentName: parent,
          );
      final classes = ['Cfg', 'Alpha', 'Beta', 'Gamma', 'Delta', 'Eps', 'Zeta'];
      final byId = <String, Symbol>{
        for (var i = 0; i < classes.length; i++)
          'lib/file$i.Cfg${classes[i]}.streamIdleTimeout': sym(
              'streamIdleTimeout', 'lib/file$i.dart',
              parent: 'Cfg${classes[i]}'),
        'lib/consumer.ProviderStreamConsumer': sym(
            'ProviderStreamConsumer', 'lib/consumer.dart'),
      };
      final table = SymbolTable.fromMap(byId);

      final results = seedQuery(table, 'stream');

      // The seven identical member names collapse to their best bearer…
      final bareNames =
          results.map((r) => r.split('.').last).toSet();
      expect(bareNames.length, results.length,
          reason: 'no bare name may appear twice: $results');
      // …and the diverse camelCase match survives them.
      expect(results.any((r) => r.contains('StreamConsumer')), isTrue,
          reason: 'Expected StreamConsumer in results: $results');
    });
  });
}
