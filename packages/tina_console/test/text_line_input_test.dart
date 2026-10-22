import 'package:tina_console/src/text_line_input.dart';
import 'package:test/test.dart';

void main() {
  group('TextLineInput', () {
    late TextLineInput edit;

    setUp(() => edit = TextLineInput());

    test('insert adds text at cursor', () {
      edit = edit.insert('hello');
      expect(edit.buffer, 'hello');
      expect(edit.cursor, 5);
    });

    test('insert in the middle', () {
      edit = TextLineInput(buffer: 'helo', cursor: 2);
      edit = edit.insert('l');
      expect(edit.buffer, 'hello');
      expect(edit.cursor, 3);
    });

    test('backspace deletes before cursor', () {
      edit = edit.insert('abc');
      edit = edit.backspace();
      expect(edit.buffer, 'ab');
      expect(edit.cursor, 2);
    });

    test('backspace at start is no-op', () {
      edit = edit.backspace();
      expect(edit.buffer, '');
      expect(edit.cursor, 0);
    });

    test('backspace handles surrogate pairs', () {
      edit = TextLineInput(buffer: 'a😀', cursor: 3); // a + emoji
      edit = edit.backspace();
      expect(edit.buffer, 'a');
      expect(edit.cursor, 1);
    });

    test('deleteForward removes char after cursor', () {
      edit = TextLineInput(buffer: 'abc', cursor: 1);
      edit = edit.deleteForward();
      expect(edit.buffer, 'ac');
      expect(edit.cursor, 1);
    });

    test('deleteForward at end is no-op', () {
      edit = TextLineInput(buffer: 'a', cursor: 1);
      edit = edit.deleteForward();
      expect(edit.buffer, 'a');
    });

    test('moveLeft and moveRight', () {
      edit = TextLineInput(buffer: 'abc', cursor: 2);
      edit = edit.moveLeft();
      expect(edit.cursor, 1);
      edit = edit.moveRight();
      expect(edit.cursor, 2);
    });

    test('moveLeft at start is no-op', () {
      edit = edit.moveLeft();
      expect(edit.cursor, 0);
    });

    test('moveRight at end is no-op', () {
      edit = TextLineInput(buffer: 'a', cursor: 1);
      edit = edit.moveRight();
      expect(edit.cursor, 1);
    });

    test('moveLeft handles surrogate pairs', () {
      edit = TextLineInput(buffer: 'a😀b', cursor: 4); // after 'b'
      edit = edit.moveLeft(); // over 'b'
      expect(edit.cursor, 3);
      edit = edit.moveLeft(); // skip over surrogate pair
      expect(edit.cursor, 1);
    });

    test('moveRight handles surrogate pairs', () {
      edit = TextLineInput(buffer: 'a😀b', cursor: 1);
      edit = edit.moveRight(); // skip over surrogate pair
      expect(edit.cursor, 3);
    });

    test('moveHome', () {
      edit = TextLineInput(buffer: 'abc', cursor: 2);
      edit = edit.moveHome();
      expect(edit.cursor, 0);
    });

    test('moveEnd', () {
      edit = TextLineInput(buffer: 'abc', cursor: 0);
      edit = edit.moveEnd();
      expect(edit.cursor, 3);
    });

    test('killToEnd', () {
      edit = TextLineInput(buffer: 'abcde', cursor: 2);
      edit = edit.killToEnd();
      expect(edit.buffer, 'ab');
      expect(edit.cursor, 2);
    });

    test('killToStart', () {
      edit = TextLineInput(buffer: 'abcde', cursor: 3);
      edit = edit.killToStart();
      expect(edit.buffer, 'de');
      expect(edit.cursor, 0);
    });

    test('clear', () {
      edit = TextLineInput(buffer: 'hello', cursor: 3);
      edit = edit.clear();
      expect(edit.buffer, '');
      expect(edit.cursor, 0);
    });

    test('replaceRange', () {
      edit = TextLineInput(buffer: 'hello world', cursor: 11);
      edit = edit.replaceRange(0, 5, 'goodbye');
      expect(edit.buffer, 'goodbye world');
      expect(edit.cursor, 7);
    });

    test('atWordBoundary at start', () {
      expect(edit.atWordBoundary(), true);
    });

    test('atWordBoundary after space', () {
      edit = TextLineInput(buffer: 'hello ', cursor: 6);
      expect(edit.atWordBoundary(), true);
    });

    test('atWordBoundary after tab', () {
      edit = TextLineInput(buffer: 'hello\t', cursor: 6);
      expect(edit.atWordBoundary(), true);
    });

    test('atWordBoundary mid-word is false', () {
      edit = TextLineInput(buffer: 'hello', cursor: 3);
      expect(edit.atWordBoundary(), false);
    });

    test('history navigation up/down', () {
      edit = TextLineInput(history: ['first', 'second', 'third']);
      edit = edit.historyUp();
      expect(edit.buffer, 'third');
      edit = edit.historyUp();
      expect(edit.buffer, 'second');
      edit = edit.historyUp();
      expect(edit.buffer, 'first');
      edit = edit.historyUp(); // already at oldest
      expect(edit.buffer, 'first');
      edit = edit.historyDown();
      expect(edit.buffer, 'second');
      edit = edit.historyDown();
      expect(edit.buffer, 'third');
      edit = edit.historyDown(); // restores draft
      expect(edit.buffer, '');
    });

    test('history preserves draft', () {
      edit = TextLineInput(buffer: 'my draft', history: ['old']);
      edit = edit.historyUp();
      expect(edit.buffer, 'old');
      edit = edit.historyDown();
      expect(edit.buffer, 'my draft');
      expect(edit.cursor, edit.buffer.length);
    });

    test('history up on empty history is no-op', () {
      edit = edit.historyUp();
      expect(edit.buffer, '');
    });

    test('addHistory dedupes consecutive', () {
      edit = edit.addHistory('hello');
      edit = edit.addHistory('hello');
      expect(edit.history.length, 1);
    });

    test('addHistory ignores blank/whitespace', () {
      edit = edit.addHistory('');
      edit = edit.addHistory('   ');
      expect(edit.history.length, 0);
    });

    test('resetNavigation clears draft', () {
      edit = TextLineInput(history: ['old'], buffer: 'draft');
      edit = edit.historyUp();
      edit = edit.resetNavigation();
      // After reset, historyDown should not restore the draft
      expect(edit.buffer, 'old'); // buffer stays as-is, just nav reset
    });
  });

  group('TextLineInput paste spans', () {
    test('display prefix hiding preserves paste spans and cursor positions',
        () {
      final edit =
          const TextLineInput().insert('!').addPaste('x' * 140).insert(' tail');
      final display = edit.display(hiddenPrefixLength: 1);
      expect(display.buffer, '[Pasted text : 140 chars] tail');
      expect(display.cursor, display.buffer.length);
      expect(edit.buffer, '!${'x' * 140} tail');
      expect(edit.copyWith(cursor: 0).display(hiddenPrefixLength: 1).cursor, 0);
      expect(edit.copyWith(cursor: 1).display(hiddenPrefixLength: 1).cursor, 0);
      expect(edit.copyWith(cursor: 141).display(hiddenPrefixLength: 1).cursor,
          '[Pasted text : 140 chars]'.length);
    });

    test('display prefix may cross paste spans without exposing controls', () {
      final edit =
          const TextLineInput().addPaste('  ').addPaste('!echo\t世界\x1b[31m!');
      expect(edit.display(hiddenPrefixLength: 3),
          (buffer: 'echo 世界!', cursor: 'echo 世界!'.length));
      expect(edit.display(hiddenPrefixLength: edit.buffer.length),
          (buffer: '', cursor: 0));
    });

    late TextLineInput edit;

    setUp(() => edit = TextLineInput());

    test('addPaste inserts real text and records a span', () {
      edit = edit.addPaste('Hello');
      expect(edit.buffer, 'Hello');
      expect(edit.cursor, 5);
      expect(edit.pasteSpans.single.start, 0);
      expect(edit.pasteSpans.single.end, 5);
      // Short pastes display verbatim, not as a chip.
      expect(edit.pasteSpans.single.display, 'Hello');
      expect(edit.toDisplay(), 'Hello');
    });

    test('short paste shows its text; long paste gets the chip', () {
      edit = edit.addPaste('short and sweet');
      expect(edit.toDisplay(), 'short and sweet');

      edit = edit.addPaste('x' * 129); // just past the verbatim limit
      // Only the long paste collapses; the earlier short one stays verbatim.
      expect(edit.toDisplay(), 'short and sweet[Pasted text : 129 chars]');
      expect(edit.buffer, 'short and sweet${'x' * 129}',
          reason: 'the real text is intact under the chip');
    });

    test('verbatim limit boundary: 128 code points in, 129 collapses', () {
      edit = edit.addPaste('y' * 128);
      expect(edit.toDisplay(), 'y' * 128);
      edit = edit.clear();
      edit = edit.addPaste('y' * 129);
      expect(edit.toDisplay(), '[Pasted text : 129 chars]');
    });

    test('short multi-line paste flattens whitespace for the single line', () {
      edit = edit.addPaste('line1\nline2\t!');
      final display = edit.toDisplay();
      expect(display, 'line1 line2 !',
          reason: 'newline and tab each become one space');
      expect(display.length, 'line1\nline2\t!'.length,
          reason: 'flattening preserves code-unit length');
      expect(edit.buffer, 'line1\nline2\t!',
          reason: 'the real text keeps its newlines for submit');
    });

    test('addPaste rune count counts code points, not units', () {
      // 129 emoji = 129 runes but 258 UTF-16 code units: past the verbatim
      // limit either way, so the chip must count runes.
      edit = edit.addPaste('😀' * 129);
      expect(edit.pasteSpans.single.display, '[Pasted text : 129 chars]');
    });

    test('verbatim decision compares runes, so wide glyphs stay visible', () {
      // 128 emoji = 128 runes (256 code units): at the limit, shown verbatim.
      edit = edit.addPaste('😀' * 128);
      expect(edit.toDisplay(), '😀' * 128);
    });

    test('toDisplay leaves surrounding text alone around a chip span', () {
      edit = edit.insert('a');
      edit = edit.addPaste('B' * 129); // chip territory
      edit = edit.insert('z');
      // Real buffer: a|BB…B|z ; display keeps the neighbors, chips the paste.
      expect(edit.toDisplay(), 'a[Pasted text : 129 chars]z');
    });

    group('chip-flush paste re-joining (one paste, split delivery)', () {
      // Burst paste detection can emit one physical paste as several
      // PasteInputs when native capture stalls (pump queue backpressure).
      // Fragments land with zero characters between them; a chip-flush
      // fragment is re-joined so the user sees ONE chip, not a row of them.
      test('paste flush against a chip merges into that chip', () {
        edit = edit.addPaste('x' * 200).addPaste('y' * 300);
        expect(edit.pasteSpans, hasLength(1),
            reason: 'delivery fragments of one paste are re-joined');
        expect(edit.pasteSpans.single.start, 0);
        expect(edit.pasteSpans.single.end, 500);
        expect(edit.pasteSpans.single.display, '[Pasted text : 500 chars]',
            reason: 'the chip counts the whole paste');
        expect(edit.buffer, 'x' * 200 + 'y' * 300,
            reason: 'real text stays intact under the merged chip');
        expect(edit.toDisplay(), '[Pasted text : 500 chars]');
      });

      test('three flush fragments collapse into one chip', () {
        edit = edit.addPaste('a' * 200).addPaste('b' * 200).addPaste('c' * 200);
        expect(edit.pasteSpans, hasLength(1));
        expect(edit.pasteSpans.single.display, '[Pasted text : 600 chars]');
      });

      test('paste separated from a chip by typed text stays separate', () {
        edit = edit.addPaste('x' * 200).insert('tail').addPaste('y' * 300);
        expect(edit.pasteSpans, hasLength(2));
        expect(edit.toDisplay(),
            '[Pasted text : 200 chars]tail[Pasted text : 300 chars]');
      });

      test('short fragment flush against a chip joins it', () {
        // Fragments as small as the detector's 8-char threshold arrive as
        // verbatim PasteInputs; flush against a chip they still re-join.
        edit = edit.addPaste('x' * 200).addPaste('abc');
        expect(edit.pasteSpans, hasLength(1));
        expect(edit.pasteSpans.single.display, '[Pasted text : 203 chars]');
        expect(edit.buffer, 'x' * 200 + 'abc');
      });

      test('paste flush against a verbatim span stays separate', () {
        edit = edit.addPaste('abc').addPaste('def');
        expect(edit.pasteSpans, hasLength(2),
            reason: 'two deliberate pastes remain individually deletable');
        expect(edit.toDisplay(), 'abcdef');
      });

      test('merged paste backspaces as one token', () {
        edit = edit.insert('pre ').addPaste('x' * 200).addPaste('y' * 200);
        edit = edit.backspace();
        expect(edit.buffer, 'pre ');
        expect(edit.pasteSpans, isEmpty);
      });
    });

    test('display cursor follows the displayed text across paste chips', () {
      edit = edit.insert('a');
      edit = edit.addPaste('BCDE'); // verbatim span [1..5), cursor at 5
      expect(edit.toDisplay().length, edit.buffer.length);
      expect(edit.displayCursor(5), 5);
      expect(edit.displayCursor(1), 1);
      edit = edit.addPaste('Z' * 129);
      expect(edit.displayCursor(edit.cursor), edit.toDisplay().length);
      expect(edit.toDisplay().length, isNot(edit.buffer.length));
      edit = edit.insert(' after');
      expect(edit.displayCursor(edit.cursor), edit.toDisplay().length);
      expect(edit.displayCursor(5), 5);
    });

    test('recalled and restored multiline input is safe without paste spans',
        () {
      const real = 'Left\nSecond\rAnother\tColumn\x1b[2J\x1b]0;title\x07';
      edit = edit.addHistory(real).historyUp();
      expect(edit.pasteSpans, isEmpty);
      expect(edit.toDisplay(), 'Left Second Another Column');
      expect(edit.displayCursor(edit.cursor), edit.toDisplay().length);
      expect(edit.buffer, real);
      edit = edit.loadState(real, real.length);
      expect(edit.toDisplay(), 'Left Second Another Column');
      expect(edit.buffer, real);
    });

    test('pasted terminal escapes cannot move the display cursor', () {
      edit = edit.addPaste('A\x1b[2JB\bC');
      expect(edit.toDisplay(), 'ABC');
      expect(edit.displayCursor(edit.cursor), 3);
      expect(edit.buffer, 'A\x1b[2JB\bC');
    });

    test('moveLeft skips over a chip as one unit', () {
      edit = edit.addPaste('H' * 140); // chip, span [0..140), cursor at 140
      edit = edit.moveLeft();
      expect(edit.cursor, 0,
          reason: 'left from the chip right edge jumps to its left edge');
    });

    test('moveRight skips over a chip as one unit', () {
      edit = edit.addPaste('H' * 140); // chip, cursor at 140
      edit = edit.copyWith(cursor: 0); // park at the chip's left edge
      edit = edit.moveRight();
      expect(edit.cursor, 140,
          reason: 'right from the chip left edge jumps to its right edge');
    });

    test('backspace at a chip right edge removes the whole chip', () {
      edit = edit.insert('a');
      edit = edit.addPaste('B' * 140); // > limit → chip, span [1..141)
      edit = edit.backspace();
      expect(edit.buffer, 'a');
      expect(edit.cursor, 1);
      expect(edit.pasteSpans, isEmpty);
    });

    test('backspace at a verbatim paste right edge deletes one character', () {
      // tin-t7-paste-backspace: a paste shown verbatim is visible text —
      // backspace removes the code unit before the cursor (the paste's last
      // character), not the whole segment.
      edit = edit.insert('a');
      edit = edit.addPaste('BCDE'); // verbatim, buffer 'aBCDE', cursor at 5
      edit = edit.backspace();
      expect(edit.buffer, 'aBCD');
      expect(edit.cursor, 4);
      expect(edit.pasteSpans.single.start, 1,
          reason: 'the remaining paste keeps its pasted marker');
      expect(edit.pasteSpans.single.end, 4);
      expect(edit.pasteSpans.single.display, 'BCD');
    });

    test('backspace shrinks a verbatim paste to empty, dropping the span', () {
      edit = edit.addPaste('xy');
      edit = edit.backspace();
      edit = edit.backspace();
      expect(edit.buffer, '');
      expect(edit.cursor, 0);
      expect(edit.pasteSpans, isEmpty,
          reason: 'an empty remaining paste carries no marker');
    });

    test('backspace inside a verbatim paste deletes the code unit before', () {
      edit = edit.addPaste('ABCD'); // verbatim, cursor at 4
      edit = edit.copyWith(cursor: 3);
      edit = edit.backspace();
      expect(edit.buffer, 'ABD');
      expect(edit.cursor, 2);
      expect(edit.pasteSpans.single.display, 'ABD');
    });

    test('deleteForward at a verbatim paste left edge deletes one character',
        () {
      edit = edit.addPaste('BCDE'); // verbatim, span [0..5)
      edit = edit.copyWith(cursor: 0);
      edit = edit.deleteForward();
      expect(edit.buffer, 'CDE');
      expect(edit.cursor, 0);
      expect(edit.pasteSpans.single.display, 'CDE');
    });

    test('display cursor follows an interior position in a verbatim span', () {
      edit = edit.insert('a');
      edit = edit.addPaste('BCDE'); // display length-preserving
      edit = edit.copyWith(cursor: 3); // between C and D
      expect(edit.displayCursor(3), 'aBC'.length);
      expect(edit.toDisplay(), 'aBCDE');
    });

    test('moveLeft steps into a verbatim paste instead of skipping it', () {
      edit = edit.addPaste('BCDE'); // verbatim, cursor at 4
      edit = edit.moveLeft();
      expect(edit.cursor, 3);
      edit = edit.moveLeft();
      expect(edit.cursor, 2);
    });

    test('moveRight still skips a chip as one unit', () {
      edit = edit.addPaste('B' * 140); // chip, cursor at 140
      edit = edit.copyWith(cursor: 0);
      edit = edit.moveRight();
      expect(edit.cursor, 140);
    });

    test('deleteForward at chip left edge removes the whole chip', () {
      edit = edit.addPaste('B' * 140); // chip, span [0..140)
      edit = edit.copyWith(cursor: 0);
      edit = edit.deleteForward();
      expect(edit.buffer, '');
      expect(edit.pasteSpans, isEmpty);
    });

    test('backspace mid-text (not at a span edge) deletes one char', () {
      edit = edit.insert('ab');
      edit = edit.addPaste('XY'); // span [2..4)
      edit = edit.copyWith(cursor: 1); // between a and b
      edit = edit.backspace();
      expect(edit.buffer, 'bXY');
      expect(edit.pasteSpans.single.start, 1);
      expect(edit.pasteSpans.single.end, 3);
    });

    test('insert shifts a following span', () {
      edit = edit.addPaste('XY'); // span [0..2)
      edit = edit.copyWith(cursor: 0);
      edit = edit.insert('Z'); // insert before the span
      expect(edit.buffer, 'ZXY');
      expect(edit.pasteSpans.single.start, 1);
      expect(edit.pasteSpans.single.end, 3);
    });

    test('killToEnd removes spans at/after the cursor', () {
      edit = edit.insert('a');
      edit = edit.addPaste('BCDE'); // span [1..6)
      edit = edit.copyWith(cursor: 1);
      edit = edit.killToEnd();
      expect(edit.buffer, 'a');
      expect(edit.pasteSpans, isEmpty);
    });

    test('killToStart removes spans before the cursor and shifts the rest', () {
      edit = edit.addPaste('AB'); // span [0..2)
      edit = edit.insert('z'); // cursor at 3, span still [0..2)
      edit = edit.addPaste('CD'); // span [3..5), cursor at 5
      edit = edit.copyWith(cursor: 3); // just before the second span
      edit = edit.killToStart();
      expect(edit.buffer, 'CD');
      // Second span shifted left by 3 → [0..2).
      expect(edit.pasteSpans.single.start, 0);
      expect(edit.pasteSpans.single.end, 2);
    });

    test('replaceRange removes overlapping spans', () {
      // Build buffer "a<BCD>e" with a paste span over BCD ([1..4)), then
      // replace [1..4) the way a completion accept would — the span is
      // dropped and the replacement lands in its place.
      edit = edit.insert('a');
      edit = edit.addPaste('BCD'); // span [1..4)
      edit = edit.copyWith(cursor: 4); // park just past the span
      edit = edit.insert('e'); // buffer "aBCDe", span [1..4)
      edit = edit.replaceRange(1, 4, 'X');
      expect(edit.buffer, 'aXe');
      expect(edit.pasteSpans, isEmpty,
          reason: 'the overlapping span is dropped');
    });

    test('history navigation clears paste spans', () {
      edit = edit.addPaste('AB');
      edit = edit.addHistory('past line');
      edit = edit.historyUp();
      expect(edit.buffer, 'past line');
      expect(edit.pasteSpans, isEmpty,
          reason: 'history holds real text only; spans are cleared');
    });

    test('clear clears buffer and spans', () {
      edit = edit.addPaste('AB');
      edit = edit.clear();
      expect(edit.buffer, '');
      expect(edit.pasteSpans, isEmpty);
    });
  });
}
