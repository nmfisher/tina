import 'dart:typed_data';

import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

void main() {
  group('Screen frame', () {
    test('redrawFrame paints the info box when split + drawInfoFrame', () {
      final io = FakeStdio();
      // Split (>=100) with a drawn info frame: the info box is the only frame
      // the Screen paints now (the chat area's border is panel-drawn).
      final layout = ScreenLayout.fromSize(100, 24, split: true, drawInfoFrame: true);
      final screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
      final vt = VirtualTerminal(width: 100, height: 24);

      screen.redrawFrame();
      vt.feed(io.written.toString());

      // Info box corners.
      expect(vt.charAt(0, layout.infoLeftCol), '┌');
      expect(vt.charAt(0, layout.infoRightCol), '┐');
      expect(vt.charAt(23, layout.infoLeftCol), '└');
      expect(vt.charAt(23, layout.infoRightCol), '┘');
      // Vertical sides on a content row.
      final r = vt.rowText(5);
      expect(r[layout.infoLeftCol], '│');
      expect(r[layout.infoRightCol], '│');
    });

    test('redrawFrame paints no box border when there is no info/menu frame', () {
      // Non-split: no info box; menu disabled. The Screen paints no box border
      // at all (the chat border is panel-drawn) — only cursor bookkeeping.
      final io = FakeStdio();
      final layout = ScreenLayout.fromSize(80, 24);
      final screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
      screen.redrawFrame();
      final out = io.written.toString();
      for (final ch in ['┌', '┐', '└', '┘', '│', '─']) {
        expect(out, isNot(contains(ch)),
            reason: 'no box border chars when no info/menu frame');
      }
    });

    test('a focused info box is cyan', () {
      final io = FakeStdio();
      final layout = ScreenLayout.fromSize(100, 24, split: true, drawInfoFrame: true);
      final screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
      screen.redrawFrame();
      io.written.clear();
      screen.focusFrame(FrameBox.info);
      expect(io.written.toString(), contains('\x1b[36m')); // cyan
    });

    test('a highlighted info box is yellow, not cyan', () {
      final io = FakeStdio();
      final layout = ScreenLayout.fromSize(100, 24, split: true, drawInfoFrame: true);
      final screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
      screen.redrawFrame();
      io.written.clear();
      screen.highlightFrame(FrameBox.info);
      final out = io.written.toString();
      expect(out, contains('\x1b[33m')); // yellow
      expect(out, isNot(contains('\x1b[36m'))); // not cyan
    });

    test('one box focused (cyan) while another is highlighted (yellow)', () {
      final io = FakeStdio();
      final layout = ScreenLayout.fromSize(100, 24, hasMenuBar: true,
          split: true, drawInfoFrame: true);
      final screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
      screen.redrawFrame();
      screen.focusFrame(FrameBox.info);
      io.written.clear();
      // While a box is highlighted (cycling), only the yellow preview shows —
      // the focus (cyan) tint is suppressed.
      screen.highlightFrame(FrameBox.menu);
      final out = io.written.toString();
      expect(out, contains('\x1b[33m')); // menu yellow
      expect(out, isNot(contains('\x1b[36m'))); // info not cyan while cycling
    });

    test('passthrough mode never emits frame escape codes', () {
      final io = FakeStdio();
      final screen = Screen.passthrough(io, ansi: AnsiCapable.yes);
      screen.enterAltScreen();
      screen.redrawFrame();
      expect(io.written.toString(), isEmpty);
    });

    test('alt-screen enter is idempotent', () {
      final io = FakeStdio();
      final screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(100, 24),
        ansi: AnsiCapable.yes,
      );
      screen.enterAltScreen();
      io.written.clear();
      screen.enterAltScreen();
      expect(io.written.toString(), isEmpty);
    });
  });

  group('Screen.renderImageAbsolute', () {
    test('ANSI backend draws a dimmed placeholder glyph via the text path', () {
      final io = FakeStdio();
      final screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(100, 24, split: true, drawInfoFrame: true),
        ansi: AnsiCapable.yes,
      );
      final vt = VirtualTerminal(width: 100, height: 24);
      screen.redrawFrame();
      io.written.clear();

      // 2x2 rgba placeholder buffer (content is irrelevant to the ANSI path).
      final rgba = Uint32List.fromList([0xff0000ff, 0x00ff00ff, 0x0000ffff, 0xffffffff]);
      screen.renderImageAbsolute(
        row: 5,
        col: 10,
        rgba: rgba,
        width: 2,
        height: 2,
        maxCols: 40,
      );
      vt.feed(io.written.toString());

      // The ANSI backend can't emit pixels: it writes a dim SGR (\x1b[2m)
      // followed by the ▣ placeholder.  Assert the glyph lands at (5, 10).
      final row = vt.rowText(5);
      expect(row.substring(10, 11), '▣');
      expect(io.written.toString(), contains('\x1b[2m'));
    });

    test('off-screen origin is a no-op (mirrors putAtAbsolute)', () {
      final io = FakeStdio();
      final screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(100, 24),
        ansi: AnsiCapable.yes,
      );
      screen.renderImageAbsolute(
        row: -1,
        col: 10,
        rgba: Uint32List(4),
        width: 2,
        height: 2,
        maxCols: 40,
      );
      screen.renderImageAbsolute(
        row: 5,
        col: -1,
        rgba: Uint32List(4),
        width: 2,
        height: 2,
        maxCols: 40,
      );
      expect(io.written.toString(), isEmpty);
    });
  });

  group('Screen.putAtAbsolute clipping', () {
    test('clips text wider than maxCols', () {
      final io = FakeStdio();
      final screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(100, 24, split: true, drawInfoFrame: true),
        ansi: AnsiCapable.yes,
      );
      final vt = VirtualTerminal(width: 100, height: 24);
      screen.redrawFrame();
      screen.putAtAbsolute(
        row: 5,
        col: 10,
        text: 'a' * 50,
        maxCols: 20,
        moveCursor: true,
      );
      vt.feed(io.written.toString());

      // 20 'a's at cols 10..29.
      final row = vt.rowText(5);
      expect(row.substring(10, 30), 'a' * 20);
      // Col 30 onward is unchanged (clipped, not overwritten).
      expect(row[30], isNot('a'));
    });

    test('repaints info borders after a write on that row', () {
      final io = FakeStdio();
      final layout = ScreenLayout.fromSize(100, 24, split: true, drawInfoFrame: true);
      final screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
      final vt = VirtualTerminal(width: 100, height: 24);
      screen.redrawFrame();

      // Write across the info left border; clipping + repair keep it intact.
      screen.putAtAbsolute(
        row: 5,
        col: layout.infoLeftCol - 5,
        text: 'x' * 200,
        maxCols: 50,
        moveCursor: true,
      );
      vt.feed(io.written.toString());
      // The info left/right borders on row 5 survive.
      expect(vt.charAt(5, layout.infoLeftCol), '│');
      expect(vt.charAt(5, layout.infoRightCol), '│');
    });

    // The defensive clip: a caller passing a content rect must never write past
    // its right edge, even on the patch path that historically clipped only to
    // the screen width. This is what keeps a stale-bounds region contained.
    test('patchAtAbsolute clips to a supplied clipRect, not the screen', () {
      final io = FakeStdio();
      final screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(100, 24, split: true, drawInfoFrame: true),
        ansi: AnsiCapable.yes,
      );
      final vt = VirtualTerminal(width: 100, height: 24);
      screen.redrawFrame();
      io.written.clear();

      // A span that would run well past col 30; clipRect caps it at col 30.
      screen.patchAtAbsolute(
        row: 5,
        col: 10,
        text: 'q' * 200,
        clearCells: 200,
        clipRect: const Rect(row: 0, col: 10, width: 20, height: 24),
      );
      vt.feed(io.written.toString());

      final row = vt.rowText(5);
      expect(row.substring(10, 30), 'q' * 20,
          reason: 'patch writes only up to the clip rect right edge');
      expect(row[30], isNot('q'),
          reason: 'nothing past the clip rect right edge');
    });

    test('putAtAbsolute clips maxCols to a supplied clipRect', () {
      final io = FakeStdio();
      final screen = Screen(
        io: io,
        layout: ScreenLayout.fromSize(100, 24, split: true, drawInfoFrame: true),
        ansi: AnsiCapable.yes,
      );
      final vt = VirtualTerminal(width: 100, height: 24);
      screen.redrawFrame();
      io.written.clear();

      // maxCols (50) is wider than the clip rect (width 20); the clip wins.
      screen.putAtAbsolute(
        row: 6,
        col: 10,
        text: 'r' * 50,
        maxCols: 50,
        moveCursor: true,
        clipRect: const Rect(row: 0, col: 10, width: 20, height: 24),
      );
      vt.feed(io.written.toString());

      final row = vt.rowText(6);
      expect(row.substring(10, 30), 'r' * 20);
      expect(row[30], isNot('r'));
    });
  });
}
