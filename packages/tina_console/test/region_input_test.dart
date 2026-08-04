import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

void main() {
  group('InputRegion', () {
    late FakeStdio io;
    late Screen screen;
    late VirtualTerminal vt;
    late ScreenLayout layout;

    setUp(() {
      io = FakeStdio();
      layout = ScreenLayout.fromSize(100, 24);
      screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
      vt = VirtualTerminal(width: 100, height: 24);
      screen.redrawFrame();
      vt.feed(io.written.toString());
      io.written.clear();
    });

    test('renders prompt + buffer on the input row', () {
      screen.input.render(prompt: '> ', buffer: 'hello', cursor: 5);
      vt.feed(io.written.toString());
      final row = vt.rowText(layout.input.row);
      expect(row.substring(layout.input.col, layout.input.col + 7), '> hello');
      // Cursor parked at end.
      expect(vt.cursorRow, layout.input.row);
      expect(vt.cursorCol, layout.input.col + 7);
    });

    test('cursor follows logical position within buffer', () {
      screen.input.render(prompt: '> ', buffer: 'abcdef', cursor: 3);
      vt.feed(io.written.toString());
      expect(vt.cursorRow, layout.input.row);
      expect(vt.cursorCol, layout.input.col + 5); // '> ' + 3 = col 5
    });

    test('long buffer scrolls horizontally, cursor stays visible', () {
      final big = 'x' * (layout.input.width * 2 + 5);
      screen.input.render(prompt: '> ', buffer: big, cursor: big.length);
      vt.feed(io.written.toString());

      // Cursor sits inside the input panel.
      expect(vt.cursorRow, layout.input.row);
      expect(vt.cursorCol < layout.dividerCol, isTrue);
      // No 'x' leaks into right panel.
      final right = vt
          .rowText(layout.input.row)
          .substring(layout.dividerCol + 1, 99);
      expect(right.contains('x'), isFalse);
    });

    test('shrinking buffer rewrites input row only', () {
      screen.input.render(prompt: '> ', buffer: 'a' * 60, cursor: 60);
      screen.input.render(prompt: '> ', buffer: 'a', cursor: 1);
      vt.feed(io.written.toString());
      // Input row shows the new short buffer.
      final inputRow = vt.rowText(layout.input.row);
      expect(inputRow.substring(layout.input.col, layout.input.col + 3), '> a');
      // Rest of input row is blank.
      final rest = inputRow.substring(layout.input.col + 3, layout.dividerCol);
      expect(rest.trim(), isEmpty);
    });

    test('clear empties the input row', () {
      screen.input.render(prompt: '> ', buffer: 'b' * 100, cursor: 100);
      screen.input.clear();
      vt.feed(io.written.toString());
      final t = vt
          .rowText(layout.input.row)
          .substring(layout.input.col, layout.dividerCol);
      expect(t.trim(), isEmpty);
    });

    test('cursor at start of long buffer shows prefix from index 0', () {
      final big = 'x' * 200;
      screen.input.render(prompt: '> ', buffer: big, cursor: 0);
      vt.feed(io.written.toString());
      // Cursor at column right after the prompt.
      expect(vt.cursorCol, layout.input.col + 2);
    });

    test('passthrough is a no-op', () {
      final io2 = FakeStdio();
      final screen2 = Screen.passthrough(io2);
      screen2.input.render(prompt: '> ', buffer: 'hi', cursor: 2);
      screen2.input.clear();
      expect(io2.written.toString(), isEmpty);
    });

    test('setBoundsOverride relocates the rendered input row', () {
      // Default: input renders at layout.input (the chat box bottom row).
      expect(screen.input.bounds, layout.input);

      // Pin it to an arbitrary rect (a side panel's bottom-interior row).
      const side = Rect(row: 20, col: 70, width: 20, height: 1);
      screen.input.setBoundsOverride(side);
      expect(screen.input.bounds, side);

      screen.input.render(prompt: '> ', buffer: 'hi', cursor: 2);
      vt.feed(io.written.toString());
      expect(vt.rowText(20).substring(70, 74), '> hi');
      expect(vt.cursorRow, 20);
      expect(vt.cursorCol, 74);

      // null returns to tracking the layout.
      screen.input.setBoundsOverride(null);
      expect(screen.input.bounds, layout.input);
    });

    test('erase blanks the current row without resetting buffer state', () {
      screen.input.render(prompt: '> ', buffer: 'keep me', cursor: 7);
      vt.feed(io.written.toString());
      expect(vt.rowText(layout.input.row).contains('keep me'), isTrue);

      io.written.clear();
      screen.input.erase();
      vt.feed(io.written.toString());
      // Row is blanked...
      final t = vt
          .rowText(layout.input.row)
          .substring(layout.input.col, layout.dividerCol);
      expect(t.trim(), isEmpty);
      // ...but a subsequent render still has the buffer (state preserved).
      io.written.clear();
      screen.input.render(
          prompt: screen.input.prompt,
          buffer: screen.input.buffer,
          cursor: screen.input.cursor);
      vt.feed(io.written.toString());
      expect(vt.rowText(layout.input.row).contains('keep me'), isTrue);
    });
  });

  // These exercise the display-space contract that LineEditor._redraw now
  // relies on: a placeholder of different width than the real paste must
  // render, scroll, and resize correctly when passed as the buffer/cursor.
  group('InputRegion display-space placeholder', () {
    late FakeStdio io;
    late Screen screen;
    late VirtualTerminal vt;
    late ScreenLayout layout;

    setUp(() {
      io = FakeStdio();
      layout = ScreenLayout.fromSize(100, 24);
      screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
      vt = VirtualTerminal(width: 100, height: 24);
      screen.redrawFrame();
      vt.feed(io.written.toString());
      io.written.clear();
    });

    test('renders the placeholder and parks the cursor at its end', () {
      const placeholder = '[Pasted text : 500 chars]'; // 24 cols
      // Display-space buffer "a" + placeholder + "z"; cursor at the
      // placeholder's right edge (display index 1 + 24 = 25).
      const display = 'a[Pasted text : 500 chars]z';
      final cursorCol = 1 + placeholder.length;
      screen.input.render(prompt: '> ', buffer: display, cursor: cursorCol);
      vt.feed(io.written.toString());
      final row = vt.rowText(layout.input.row);
      // The rendered substring includes the prompt + display text.
      expect(
          row.substring(layout.input.col,
              layout.input.col + 2 + display.length),
          '> $display');
      expect(vt.cursorRow, layout.input.row);
      expect(vt.cursorCol, layout.input.col + 2 + cursorCol);
    });

    test('long placeholder scrolls horizontally, cursor stays visible', () {
      // A wide display buffer must scroll so the cursor stays on-screen and
      // nothing leaks past the input panel into the right panel.
      final display = 'x' * (layout.input.width * 2 + 5);
      screen.input.render(
          prompt: '> ', buffer: display, cursor: display.length);
      vt.feed(io.written.toString());
      expect(vt.cursorRow, layout.input.row);
      expect(vt.cursorCol < layout.dividerCol, isTrue);
      final right = vt
          .rowText(layout.input.row)
          .substring(layout.dividerCol + 1, 99);
      expect(right.contains('x'), isFalse);
    });

    test('resize re-renders the placeholder from stored display state', () {
      const display = 'a[Pasted text : 500 chars]z';
      final cursorCol = 1 + '[Pasted text : 500 chars]'.length;
      screen.input.render(prompt: '> ', buffer: display, cursor: cursorCol);
      vt.feed(io.written.toString());
      io.written.clear();
      // Resize triggers handleResize, which re-renders from the stored
      // display-space buffer/cursor.
      screen.resize(ScreenLayout.fromSize(100, 24));
      vt.feed(io.written.toString());
      expect(
          vt.rowText(layout.input.row).contains('[Pasted text : 500 chars]'),
          isTrue);
    });
  });
}
