import 'package:fuzzy_ranker/fuzzy_ranker.dart';
import 'package:test/test.dart';

void main() {
  group('fuzzyScore', () {
    test('empty query scores zero on any candidate', () {
      expect(fuzzyScore('', 'whatever'), 0);
      expect(fuzzyScore('', ''), 0);
    });

    test('non-subsequence returns null', () {
      expect(fuzzyScore('xyz', 'lib/repl.dart'), isNull);
      expect(fuzzyScore('rep', 'foo/bar.dart'), isNull);
    });

    test('contiguous match beats scattered subsequence', () {
      final contiguous = fuzzyScore('rep', 'lib/repl.dart')!;
      final scattered = fuzzyScore('rep', 'src/responder_proxy.dart')!;
      expect(contiguous, greaterThan(scattered));
    });

    test('word-boundary match beats mid-word match', () {
      final boundary = fuzzyScore('p', 'lib/policy.dart')!;
      final midWord = fuzzyScore('p', 'application.dart')!;
      expect(boundary, greaterThan(midWord));
    });

    test('case-exact match beats case-insensitive match', () {
      final exact = fuzzyScore('R', 'Renderer')!;
      final insensitive = fuzzyScore('R', 'renderer')!;
      expect(exact, greaterThan(insensitive));
    });

    test('query is case-insensitive for the subsequence check', () {
      expect(fuzzyScore('REP', 'lib/repl.dart'), isNotNull);
      expect(fuzzyScore('rep', 'lib/REPL.DART'), isNotNull);
    });

    test('shorter candidate wins on ties', () {
      // Both contain "rep" at the same boundary position.
      final shorter = fuzzyScore('rep', 'rep.dart')!;
      final longer = fuzzyScore('rep', 'rep_long_name.dart')!;
      expect(shorter, greaterThan(longer));
    });
  });

  group('rankFuzzy', () {
    test('orders by descending score, drops non-matches', () {
      final candidates = [
        'lib/permissions/prompt.dart',
        'foo/bar.dart',
        'lib/repl.dart',
        'test/repl_test.dart',
      ];
      final ranked = rankFuzzy('repl', candidates);
      expect(ranked, isNot(contains('foo/bar.dart')));
      // The exact-prefix path-segment hit should come first.
      expect(ranked.first, 'lib/repl.dart');
      expect(ranked, contains('test/repl_test.dart'));
    });

    test('empty query preserves input order', () {
      final input = ['c', 'a', 'b'];
      expect(rankFuzzy('', input), ['c', 'a', 'b']);
    });

    test('no matches returns empty list', () {
      expect(rankFuzzy('xyz', ['a', 'b']), isEmpty);
    });

    test('does not mutate the input', () {
      final input = ['b.dart', 'a.dart'];
      final copy = List<String>.from(input);
      rankFuzzy('a', input);
      expect(input, copy);
    });
  });
}
