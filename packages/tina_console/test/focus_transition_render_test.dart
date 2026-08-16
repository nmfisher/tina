import 'dart:async';
import 'dart:typed_data';

import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';

/// A [TerminalBackend] that records every styled write at its absolute
/// (row, col), so a test can inspect the *sequence* of border paints across a
/// focus transition — not just the final frame. A [VirtualTerminal] can't do
/// this: it keeps only the last frame, so a transient in-between repaint (the
/// bug we're guarding against) is overwritten and invisible.
class _RecordBackend implements TerminalBackend {

  // No retained damage model in this fake; refresh is a no-op.
  @override
  void refresh() {}
  final List<({int row, int col, String text})> writes = [];
  int _r = 0;
  int _c = 0;

  void clear() => writes.clear();

  @override
  void beginFrame() {}

  @override
  void endFrame() {}

  @override
  void parkCursor(int row, int col) => moveCursor(row, col);

  @override
  void moveCursor(int row, int col) {
    _r = row;
    _c = col;
  }

  @override
  void eraseCells(int row, int col, int n) {
    _r = row;
    _c = col;
  }

  @override
  void writeText(String text) => writes.add((row: _r, col: _c, text: text));

  @override
  void saveCursor() {}

  @override
  void restoreCursor() {}

  @override
  void flush() {}

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
  int get terminalColumns => 120;

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

  @override
  BackendSurface createSurface(Rect bounds) =>
      throw UnimplementedError('panels in this test write via putAtAbsolute');
}

void main() {
  // Guards the class of bug where a focus transition paints an intermediate,
  // unaccented (plain) frame — e.g. commit() unhighlighting the target before
  // focusing it, which read as a yellow -> black -> cyan flash. The target's
  // side-border cells must go straight from the highlight accent to the focus
  // accent, never through a plain (bare-`│`) paint.
  group('focus transition rendering', () {
    late _RecordBackend backend;
    late Screen screen;
    late PanelFrame panelA;
    late PanelFrame panelB;

    setUp(() {
      final io = FakeStdio()..columns = 120;
      final layout = ScreenLayout.fromSize(120, 24);
      backend = _RecordBackend();
      screen = Screen.withBackend(
          backend: backend, io: io, layout: layout, ansi: AnsiCapable.yes);

      // Two panels in disjoint columns so their border cells can be told apart
      // in the write log.
      panelA = PanelFrame(
        screen: screen,
        label: 'a',
        conversationId: 'a',
      )..setOuter(const Rect(row: 0, col: 0, width: 40, height: 24));
      panelB = PanelFrame(
        screen: screen,
        label: 'b',
        conversationId: 'b',
      )..setOuter(const Rect(row: 0, col: 50, width: 40, height: 24));
    });

    test('commit never paints the target border without an accent', () {
      final fm = FocusManager()
        ..register(panelA)
        ..register(panelB)
        ..home = panelA; // panelA focused (cyan) at start
      fm.engage(); // -> panelA highlighted (yellow)
      fm.moveHighlightCyclic(1); // -> panelB highlighted (yellow)

      // Inspect only the commit's own renders.
      backend.clear();
      fm.commit(); // panelB becomes the focus (cyan); panelA blurs

      // A bare `│` (no SGR) at panelB's border columns is a plain, unaccented
      // paint — the intermediate frame that read as a flash.
      final plainTargetBorder = backend.writes.where((w) =>
          (w.col == panelB.bounds.col || w.col == panelB.bounds.right) &&
          w.text == '│');
      expect(plainTargetBorder, isEmpty,
          reason: 'commit must take the target yellow -> cyan directly, '
              'with no plain (unaccented) border repaint between');
    });
  });
}
