// Quote-aware word parsing for `!`-mode (shell passthrough) lines: the
// mode predicate mirrors the host's submit routing (trim, then the `!`
// input prefix), words split the way a shell splits them for completion,
// and the cursor word is what Tab completes.
library;

import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

void main() {
  group('bangIndex / isBangLine — mirrors submit routing', () {
    test('plain bang line', () {
      expect(bangIndex('!git status'), 0);
      expect(isBangLine('!git status'), isTrue);
    });

    test('leading whitespace still routes to the shell', () {
      expect(bangIndex('  \t!git'), 3);
      expect(isBangLine('  !git'), isTrue);
    });

    test('double bang is a bang line (the host prefix match takes one !)', () {
      expect(isBangLine('!!history'), isTrue);
      expect(bangIndex('!!history'), 0);
    });

    test('a bang anywhere else is ordinary input', () {
      expect(isBangLine('text !'), isFalse);
      expect(isBangLine('hello!'), isFalse);
      expect(isBangLine(''), isFalse);
      expect(isBangLine('   '), isFalse);
    });
  });

  group('bangWords — shell-like splitting with quotes retained', () {
    test('simple words with single and multiple spaces', () {
      final words = bangWords('!git  status -s');
      expect(words.map((w) => w.text), ['git', 'status', '-s']);
      expect(words.map((w) => w.start), [1, 6, 13]);
      expect(words.every((w) => w.quote == null && w.closed), isTrue);
    });

    test('trailing and empty words are skipped, not emitted', () {
      expect(bangWords('!git status  ').map((w) => w.text), ['git', 'status']);
      expect(bangWords('!'), isEmpty);
      expect(bangWords('!  '), isEmpty);
    });

    test('single quotes keep spaces inside one word', () {
      final words = bangWords("!cat 'my file.txt' tail");
      expect(words.map((w) => w.text), ['cat', "'my file.txt'", 'tail']);
      expect(words[1].quote, "'");
      expect(words[1].closed, isTrue);
    });

    test('double quotes keep spaces inside one word', () {
      final words = bangWords('!cat "my file.txt"');
      expect(words.map((w) => w.text), ['cat', '"my file.txt"']);
      expect(words[1].quote, '"');
    });

    test('an unterminated quote runs to the end of the line', () {
      final words = bangWords("!cat 'open ended");
      expect(words.map((w) => w.text), ['cat', "'open ended"]);
      expect(words[1].quote, "'");
      expect(words[1].closed, isFalse);
    });

    test('a quoted segment glues to adjacent text', () {
      final words = bangWords("!echo 'a'b c");
      expect(words.map((w) => w.text), ['echo', "'a'b", 'c']);
    });

    test('a non-bang line has no words', () {
      expect(bangWords('git status'), isEmpty);
      expect(bangWords(''), isEmpty);
    });

    test('query strips the quotes the word carries', () {
      expect(bangWords("!cat 'my f'")[1].query, 'my f');
      expect(bangWords('!cat "x"')[1].query, 'x');
      expect(bangWords("!cat 'open")[1].query, 'open');
      expect(bangWords('!git').first.query, 'git');
      expect(bangWords("!cat ''")[1].query, '');
    });
  });

  group('bangWordAtCursor — the word Tab completes', () {
    test('the command word, cursor inside it', () {
      final at = bangWordAtCursor('!gi', 3);
      expect(at, isNotNull);
      expect(at!.word.text, 'gi');
      expect(at.word.start, 1);
      expect(at.isCommandWord, isTrue);
    });

    test('cursor right after the bang: empty command word', () {
      final at = bangWordAtCursor('!', 1);
      expect(at!.word.text, '');
      expect(at.word.start, 1);
      expect(at.isCommandWord, isTrue);
    });

    test('later words are path words', () {
      final at = bangWordAtCursor('!git sta', 8);
      expect(at!.word.text, 'sta');
      expect(at.isCommandWord, isFalse);
      expect(at.word.start, 5);
    });

    test('cursor after a space: empty word anchored at the cursor', () {
      final at = bangWordAtCursor('!git ', 5);
      expect(at!.word.text, '');
      expect(at.word.start, 5);
      expect(at.isCommandWord, isFalse);
    });

    test('multiple spaces: the word starts after the last one', () {
      final at = bangWordAtCursor('!git   sta', 10);
      expect(at!.word.start, 7);
      expect(at.word.text, 'sta');
    });

    test('a quoted word under the cursor carries its quote', () {
      final at = bangWordAtCursor("!cat 'my f", 10);
      expect(at!.word.text, "'my f");
      expect(at.word.quote, "'");
      expect(at.word.closed, isFalse);
      expect(at.word.query, 'my f');
      expect(at.isCommandWord, isFalse);
    });

    test('a fully typed quoted word is closed and queries its inside', () {
      final at = bangWordAtCursor("!cat 'my f'", 11);
      expect(at!.word.closed, isTrue);
      expect(at.word.query, 'my f');
    });

    test('cursor inside a word completes up to the cursor', () {
      final at = bangWordAtCursor('!git status', 9);
      expect(at!.word.text, 'stat');
    });

    test('cursor at or before the bang completes nothing', () {
      expect(bangWordAtCursor('!git', 0), isNull);
      expect(bangWordAtCursor(' !git', 1), isNull);
      expect(bangWordAtCursor('!git', 1)!.word.text, '');
    });

    test('non-bang lines complete nothing', () {
      expect(bangWordAtCursor('git status', 4), isNull);
      expect(bangWordAtCursor('text !', 6), isNull);
    });
  });
}
