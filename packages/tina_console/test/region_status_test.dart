import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

void main() {
  group('StatusRegion', () {
    late FakeStdio io;
    late Screen screen;
    late VirtualTerminal vt;
    late ScreenLayout layout;

    setUp(() {
      io = FakeStdio();
      layout = ScreenLayout.fromSize(120, 30);
      screen = Screen(io: io, layout: layout, ansi: AnsiCapable.yes);
      vt = VirtualTerminal(width: 120, height: 30);
      screen.redrawFrame();
      vt.feed(io.written.toString());
      io.written.clear();
    });

    test('writes a single row of the right panel', () {
      screen.status.writeAt(2, 'working');
      vt.feed(io.written.toString());
      final row = vt.rowText(layout.status.row + 2);
      expect(row.substring(layout.status.col, layout.status.col + 7), 'working');
    });

    test('clears a row and restores borders', () {
      screen.status.writeAt(2, 'working');
      screen.status.clearAt(2);
      vt.feed(io.written.toString());
      final right = vt
          .rowText(layout.status.row + 2)
          .substring(layout.status.col, layout.rightBorderCol);
      expect(right.trim(), isEmpty);
      vt.assertBorders(layout.status.row + 2, layout.infoLeftCol,
          layout.infoRightCol, layout.infoRightCol);
    });

    test('does not move the visible cursor', () {
      // Park visible cursor first.
      screen.parkCursorAt(10, 50);
      io.written.clear();
      screen.status.writeAt(0, 'x');
      // Output must contain save+restore so the cursor parks back at (10, 50).
      final out = io.written.toString();
      expect(out, contains('\x1b7'));
      expect(out, contains('\x1b8'));
    });

    test('text wider than panel is clipped, never crosses border', () {
      screen.status.writeAt(0, 'q' * 500);
      vt.feed(io.written.toString());
      vt.assertBorders(layout.status.row, layout.infoLeftCol,
          layout.infoRightCol, layout.infoRightCol);
      // No q's leaked left of the divider.
      final left = vt
          .rowText(layout.status.row)
          .substring(layout.chat.col, layout.dividerCol);
      expect(left.contains('q'), isFalse);
    });

    test('passthrough mode is a no-op', () {
      final io2 = FakeStdio();
      final screen2 = Screen.passthrough(io2);
      screen2.status.writeAt(0, 'hi');
      screen2.status.clearAt(0);
      screen2.status.clear();
      expect(io2.written.toString(), isEmpty);
    });
  });
}
