// patchStyledAtAbsolute primitive + renderStyledRuns emission tests.
//
// Proves the style-aware partial-write primitive re-emits a changed run span
// from a known default baseline (one leading reset, then each run's complete
// SGR + text) and clears only the old tail width — the byte-level contract the
// null-surface styled-diff path relies on. A recording fake captures the exact
// moveCursor/eraseCells/writeText sequence so we can assert it independently of
// the VT cell model (which is fragile for embedded SGR).

import 'dart:typed_data';

import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/styled_text.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';

void main() {
  group('patchStyledAtAbsolute', () {
    test('emits one reset + per-run SGR + text, clears only old tail width',
        () {
      // Row was "\x1b[32mAB\x1b[36mCD\x1b[0m"; tail run changes CD→CE (blue→
      // cyan). Prefix "AB" green is unchanged; we patch from col 2, clearing the
      // old 2-cell tail and re-emitting only the changed tail span.
      final fake = _RecBackend();
      final screen = Screen.withBackend(
        backend: fake,
        io: FakeStdio(),
        layout: ScreenLayout.fromSize(80, 24, split: false),
        ansi: AnsiCapable.yes,
      );
      final oldRuns = parseStyledRuns('\x1b[32mAB\x1b[36mCD\x1b[0m');
      final newRuns = parseStyledRuns('\x1b[32mAB\x1b[36mCE\x1b[0m');
      final span = diffStyledRuns(oldRuns, newRuns)!;
      expect(span.startIndex, 1);
      expect(span.colOffset, 2);

      screen.patchStyledAtAbsolute(
        row: 5,
        col: 10 + span.colOffset,
        runs: span.runs,
        clearCells: 2, // old tail "CD" width
      );

      // Exactly one erase of the old tail (2 cells), and the written text is the
      // self-contained changed tail: reset, cyan "CE" (truecolor), trailing
      // reset. Basic cyan is stored as 0x00cdcd → 38;2;0;205;205.
      expect(fake.erases, hasLength(1));
      expect(fake.erases.first, _Erase(5, 12, 2));
      expect(fake.written, [
        '\x1b[0m', // leading reset (known baseline)
        '\x1b[0m\x1b[38;2;0;205;205mCE\x1b[0m', // renderStyledRuns: [cyan CE, reset]
      ]);
      // Cursor parked at the span origin before the write (moveCursor called
      // twice: once pre-reset, once post-erase).
      expect(fake.moves.where((m) => m.row == 5 && m.col == 12), hasLength(2));
    });

    test('clearCells clips to remaining row width', () {
      final fake = _RecBackend();
      final screen = Screen.withBackend(
        backend: fake,
        io: FakeStdio(),
        layout: ScreenLayout.fromSize(10, 24, split: false),
        ansi: AnsiCapable.yes,
      );
      final runs = parseStyledRuns('\x1b[31mX\x1b[0m');
      final span = StyledRunSpan(0, runs, 0);
      // Ask to clear 100 cells at col 8 on a 10-wide row → clips to 2.
      screen.patchStyledAtAbsolute(
        row: 0,
        col: 8,
        runs: span.runs,
        clearCells: 100,
      );
      expect(fake.erases.first.n, 2);
    });
  });
}

class _Move {
  final int row, col;
  _Move(this.row, this.col);
  @override
  bool operator ==(Object other) =>
      other is _Move && other.row == row && other.col == col;
  @override
  int get hashCode => Object.hash(row, col);
  @override
  String toString() => '_Move($row,$col)';
}

class _Erase {
  final int row, col, n;
  _Erase(this.row, this.col, this.n);
  @override
  bool operator ==(Object other) =>
      other is _Erase && other.row == row && other.col == col && other.n == n;
  @override
  int get hashCode => Object.hash(row, col, n);
  @override
  String toString() => '_Erase($row,$col,$n)';
}

/// Minimal recording fake: captures moves, erases, and the concatenated text
/// written. Renders nothing — tests assert on the call sequence.
class _RecBackend implements TerminalBackend {
  final List<_Move> moves = [];
  final List<_Erase> erases = [];
  final List<String> written = [];
  int _frameDepth = 0;
  bool _flushPending = false;

  @override
  void beginFrame() => _frameDepth++;

  @override
  void endFrame() {
    if (_frameDepth == 0) return;
    _frameDepth--;
    if (_frameDepth == 0 && _flushPending) {
      _flushPending = false;
    }
  }

  @override
  void moveCursor(int row, int col) => moves.add(_Move(row, col));

  @override
  void parkCursor(int row, int col) => moveCursor(row, col);

  @override
  void eraseCells(int row, int col, int n) => erases.add(_Erase(row, col, n));

  @override
  void writeText(String text) => written.add(text);

  @override
  void saveCursor() {}

  @override
  void restoreCursor() {}

  @override
  void flush() {
    if (_frameDepth > 0) {
      _flushPending = true;
      return;
    }
  }

  @override
  void enterAltScreen() {}

  @override
  void leaveAltScreen() {}

  @override
  void enableBracketedPaste() {}

  @override
  void disableBracketedPaste() {}

  @override
  bool get supportsColor => true;

  // Synchronous-style recording backend: no coalesced chat scheduling.
  @override
  bool get coalescesPaints => false;

  @override
  String colorize(String code, String text) => '\x1b[${code}m$text\x1b[0m';

  @override
  Stream<List<int>> get stdin => const Stream.empty();

  @override
  int get terminalColumns => 80;

  @override
  BackendSurface createSurface(Rect bounds) =>
      throw UnimplementedError('unused');

  @override
  void renderImageAbsolute({
    required int row,
    required int col,
    required Uint32List rgba,
    required int width,
    required int height,
    required int maxCols,
    BackendSurface? targetSurface,
  }) {}
}
