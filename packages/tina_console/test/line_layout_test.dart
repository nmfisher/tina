import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

void main() {
  group('computeLineLayout', () {
    test('empty buffer sits on the prompt row', () {
      final l = computeLineLayout(
        promptCols: 2,
        bufferLen: 0,
        cursor: 0,
        cols: 80,
      );
      expect(l.cursorRow, 0);
      expect(l.cursorCol, 2);
      expect(l.endRow, 0);
    });

    test('single-row input — cursor mid-buffer', () {
      final l = computeLineLayout(
        promptCols: 2,
        bufferLen: 10,
        cursor: 4,
        cols: 80,
      );
      expect(l.cursorRow, 0);
      expect(l.cursorCol, 6);
      expect(l.endRow, 0);
    });

    test('buffer wraps to a second row; cursor at end', () {
      // promptCols 2 + bufferLen 20 = 22 total, width 10 →
      // rows occupied: 0 (cols 2..9), 1 (cols 0..9), 2 (cols 0..1)
      // endTotal=22, last char at col 1 of row 2 → endRow = (22-1)/10 = 2
      // cursor at end → cursorTotal=22 → row=2, col=2
      final l = computeLineLayout(
        promptCols: 2,
        bufferLen: 20,
        cursor: 20,
        cols: 10,
      );
      expect(l.endRow, 2);
      expect(l.cursorRow, 2);
      expect(l.cursorCol, 2);
    });

    test('buffer wraps; cursor on the first row', () {
      final l = computeLineLayout(
        promptCols: 2,
        bufferLen: 20,
        cursor: 3,
        cols: 10,
      );
      expect(l.endRow, 2);
      expect(l.cursorRow, 0);
      expect(l.cursorCol, 5);
    });

    test('buffer ends exactly at right edge of a row', () {
      // 2 + 8 = 10 = one full row at width 10. Last char at col 9 of row 0.
      final l = computeLineLayout(
        promptCols: 2,
        bufferLen: 8,
        cursor: 8,
        cols: 10,
      );
      expect(l.endRow, 0);
      // Cursor logically sits at col 10 (off the right) — modulo gives 0
      // on the next row. The redraw code uses this to land at row 1 col 0,
      // which is where the terminal will place the cursor after writing 8
      // chars past col 1 with auto-wrap.
      expect(l.cursorRow, 1);
      expect(l.cursorCol, 0);
    });

    test('buffer crosses many rows at narrow width', () {
      final l = computeLineLayout(
        promptCols: 2,
        bufferLen: 100,
        cursor: 50,
        cols: 20,
      );
      // endTotal=102, endRow=(102-1)/20 = 5
      // cursorTotal=52, row=2, col=12
      expect(l.endRow, 5);
      expect(l.cursorRow, 2);
      expect(l.cursorCol, 12);
    });

    test('zero / negative cols falls back to 80', () {
      final l = computeLineLayout(
        promptCols: 2,
        bufferLen: 10,
        cursor: 5,
        cols: 0,
      );
      expect(l.cursorRow, 0);
      expect(l.cursorCol, 7);
      expect(l.endRow, 0);
    });

    test('cursor at start of buffer', () {
      final l = computeLineLayout(
        promptCols: 2,
        bufferLen: 30,
        cursor: 0,
        cols: 10,
      );
      expect(l.cursorRow, 0);
      expect(l.cursorCol, 2);
      // endTotal=32 → endRow=(32-1)/10 = 3
      expect(l.endRow, 3);
    });
  });

  group('stripAnsi', () {
    test('removes CSI SGR sequences', () {
      expect(stripAnsi('\x1b[36mtina\x1b[0m'), 'tina');
      expect(stripAnsi('\x1b[1;33mwarn\x1b[0m: foo'), 'warn: foo');
    });

    test('removes cursor-movement CSI sequences', () {
      expect(stripAnsi('\r\x1b[K> '), '\r> ');
      expect(stripAnsi('\x1b[2J\x1b[Hfoo'), 'foo');
    });

    test('passes plain strings through untouched', () {
      expect(stripAnsi('> '), '> ');
      expect(stripAnsi(''), '');
    });
  });
}
