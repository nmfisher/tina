import 'package:tina_console/src/text_buffer.dart';
import 'package:test/test.dart';

void main() {
  group('TextBuffer', () {
    test('default is empty with cursor at (0,0)', () {
      final b = TextBuffer();
      expect(b.text, '');
      expect(b.line, 0);
      expect(b.col, 0);
      expect(b.lineCount, 1);
    });

    test('seeds text and places the cursor at the end', () {
      final b = TextBuffer(initial: 'hello');
      expect(b.text, 'hello');
      expect(b.line, 0);
      expect(b.col, 5);
    });

    test('seeds multiline text; cursor at end of the last line', () {
      final b = TextBuffer(initial: 'a\nb\nc');
      expect(b.lines, ['a', 'b', 'c']);
      expect(b.line, 2);
      expect(b.col, 1);
    });

    test('a trailing newline leaves an empty last line', () {
      final b = TextBuffer(initial: 'a\n');
      expect(b.lines, ['a', '']);
      expect(b.line, 1);
      expect(b.col, 0);
    });

    test('text round-trips through a seed', () {
      const seed = 'You are an agent.\n\nBe concise.\nCite paths.';
      expect(TextBuffer(initial: seed).text, seed);
    });

    group('insert', () {
      test('adds text at the cursor on one line', () {
        final b = TextBuffer(initial: 'hello');
        b.moveLineHome();
        b.insert('XX');
        expect(b.text, 'XXhello');
        expect(b.col, 2);
      });

      test('inserts in the middle of a line', () {
        final b = TextBuffer(initial: 'helo');
        b.col = 2; // after "he"
        b.insert('l');
        expect(b.text, 'hello');
        expect(b.col, 3);
      });

      test('a newline in the inserted text splits the line', () {
        final b = TextBuffer(initial: 'abc');
        b.col = 1; // a|bc
        b.insert('X\nY');
        expect(b.lines, ['aX', 'Ybc']);
        expect(b.line, 1);
        expect(b.col, 1); // after "Y" in "Ybc"
      });

      test('inserting a single newline is the same as splitLine', () {
        final a = TextBuffer(initial: 'abc')..col = 1..insert('\n');
        final b = TextBuffer(initial: 'abc')..col = 1..splitLine();
        expect(a.text, b.text);
        expect(a.line, b.line);
        expect(a.col, b.col);
      });

      test('empty insert is a no-op', () {
        final b = TextBuffer(initial: 'abc');
        b.insert('');
        expect(b.text, 'abc');
        expect(b.col, 3);
      });
    });

    group('splitLine', () {
      test('breaks the current line at the cursor', () {
        final b = TextBuffer(initial: 'hello');
        b.col = 2;
        b.splitLine();
        expect(b.lines, ['he', 'llo']);
        expect(b.line, 1);
        expect(b.col, 0);
      });

      test('at end of line creates a trailing empty line', () {
        final b = TextBuffer(initial: 'ab');
        b.splitLine();
        expect(b.lines, ['ab', '']);
        expect(b.line, 1);
      });
    });

    group('backspace', () {
      test('deletes the code point before the cursor', () {
        final b = TextBuffer(initial: 'abc');
        b.backspace();
        expect(b.text, 'ab');
        expect(b.col, 2);
      });

      test('at column 0 joins onto the previous line', () {
        final b = TextBuffer(initial: 'ab\ncd');
        b.line = 1; // start of second line
        b.col = 0;
        b.backspace();
        expect(b.lines, ['abcd']);
        expect(b.line, 0);
        expect(b.col, 2); // at the join
      });

      test('at the very start is a no-op', () {
        final b = TextBuffer();
        b.backspace();
        expect(b.text, '');
        expect(b.line, 0);
        expect(b.col, 0);
      });

      test('handles surrogate pairs', () {
        final b = TextBuffer(initial: 'a😀');
        b.backspace();
        expect(b.text, 'a');
        expect(b.col, 1);
      });
    });

    group('deleteForward', () {
      test('removes the code point after the cursor', () {
        final b = TextBuffer(initial: 'abc');
        b.col = 1;
        b.deleteForward();
        expect(b.text, 'ac');
        expect(b.col, 1);
      });

      test('at end of line joins the next line in', () {
        final b = TextBuffer(initial: 'ab\ncd');
        b.line = 0;
        b.col = 2; // end of "ab"
        b.deleteForward();
        expect(b.lines, ['abcd']);
        expect(b.col, 2);
      });

      test('at the very end is a no-op', () {
        final b = TextBuffer(initial: 'ab\ncd');
        b.deleteForward();
        expect(b.text, 'ab\ncd');
      });

      test('handles surrogate pairs', () {
        final b = TextBuffer(initial: 'a😀b');
        b.col = 1;
        b.deleteForward();
        expect(b.text, 'ab');
      });
    });

    group('horizontal movement', () {
      test('moveLeft/Right within a line', () {
        final b = TextBuffer(initial: 'abc');
        b.col = 0;
        b.moveRight();
        b.moveRight();
        expect(b.col, 2);
        b.moveLeft();
        expect(b.col, 1);
      });

      test('moveLeft at col 0 wraps to the end of the previous line', () {
        final b = TextBuffer(initial: 'ab\ncd');
        b.line = 1;
        b.col = 0;
        b.moveLeft();
        expect(b.line, 0);
        expect(b.col, 2);
      });

      test('moveRight at end wraps to the start of the next line', () {
        final b = TextBuffer(initial: 'ab\ncd');
        b.line = 0;
        b.col = 2;
        b.moveRight();
        expect(b.line, 1);
        expect(b.col, 0);
      });

      test('moveLeft at the very start is a no-op', () {
        final b = TextBuffer(initial: 'ab\ncd');
        b.line = 0;
        b.col = 0;
        b.moveLeft();
        expect(b.line, 0);
        expect(b.col, 0);
      });

      test('moveRight at the very end is a no-op', () {
        final b = TextBuffer(initial: 'ab\ncd');
        b.moveRight();
        expect(b.line, 1);
        expect(b.col, 2);
      });

      test('movement is surrogate-aware', () {
        final b = TextBuffer(initial: 'a😀b');
        b.col = 0;
        b.moveRight(); // over "a"
        expect(b.col, 1);
        b.moveRight(); // skip the surrogate pair
        expect(b.col, 3);
        b.moveLeft(); // back over the pair
        expect(b.col, 1);
      });
    });

    group('vertical movement', () {
      test('moveUp/moveDown change the line', () {
        final b = TextBuffer(initial: 'aaa\nbbb\nccc');
        b.line = 0;
        b.moveDown();
        expect(b.line, 1);
        b.moveDown();
        expect(b.line, 2);
      });

      test('col clamps to the target line length', () {
        final b = TextBuffer(initial: 'aaaaa\nb');
        b.line = 0;
        b.col = 5; // end of "aaaaa"
        b.moveDown(); // onto "b"
        expect(b.line, 1);
        expect(b.col, 1); // clamped
      });

      test('moveUp at the first line is a no-op', () {
        final b = TextBuffer(initial: 'a\nb');
        b.line = 0;
        b.moveUp();
        expect(b.line, 0);
      });

      test('moveDown at the last line is a no-op', () {
        final b = TextBuffer(initial: 'a\nb');
        b.moveDown();
        expect(b.line, 1);
      });
    });

    test('moveLineHome / moveLineEnd', () {
      final b = TextBuffer(initial: 'hello');
      b.col = 2;
      b.moveLineEnd();
      expect(b.col, 5);
      b.moveLineHome();
      expect(b.col, 0);
    });

    test('clear resets to empty', () {
      final b = TextBuffer(initial: 'a\nb\nc');
      b.clear();
      expect(b.text, '');
      expect(b.line, 0);
      expect(b.col, 0);
      expect(b.lineCount, 1);
    });

    test('lines view is unmodifiable', () {
      final b = TextBuffer(initial: 'a\nb');
      expect(() => b.lines.add('c'), throwsUnsupportedError);
    });
  });
}
