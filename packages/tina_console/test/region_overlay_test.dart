import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'stdio_fake.dart';
import 'virtual_terminal.dart';

void main() {
  group('OverlayRegion', () {
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

    test('show writes lines, hide clears and repaints borders', () {
      final overlay = OverlayRegion(
        screen,
        const Rect(row: 10, col: 5, width: 20, height: 3),
      );
      overlay.show(['line A', 'line B', 'line C']);
      vt.feed(io.written.toString());
      expect(vt.rowText(10).substring(5, 11), 'line A');
      expect(vt.rowText(11).substring(5, 11), 'line B');
      expect(vt.rowText(12).substring(5, 11), 'line C');

      overlay.hide();
      vt.feed(io.written.toString());
      for (var r = 10; r <= 12; r++) {
        final t = vt.rowText(r).substring(5, 25);
        expect(t.trim(), isEmpty, reason: 'row $r should be blank');
      }
      // Info-box borders intact.
      for (var r = 10; r <= 12; r++) {
        vt.assertBorders(r, layout.infoLeftCol, layout.infoRightCol,
            layout.infoRightCol);
      }
      overlay.dispose();
    });

    test('show clips lines longer than width', () {
      final overlay = OverlayRegion(
        screen,
        const Rect(row: 5, col: 5, width: 6, height: 1),
      );
      overlay.show(['HELLO WORLD']);
      vt.feed(io.written.toString());
      final row = vt.rowText(5);
      expect(row.substring(5, 11), 'HELLO ');
      expect(row.substring(11, 12), isNot('W'));
      overlay.dispose();
    });

    test('reposition hides old rectangle', () {
      final overlay = OverlayRegion(
        screen,
        const Rect(row: 5, col: 5, width: 10, height: 1),
      );
      overlay.show(['hi']);
      overlay.reposition(const Rect(row: 8, col: 5, width: 10, height: 1));
      overlay.show(['ok']);
      vt.feed(io.written.toString());

      // Old row blanked.
      final oldRow = vt.rowText(5).substring(5, 15);
      expect(oldRow.trim(), isEmpty);
      // New row has content.
      final newRow = vt.rowText(8);
      expect(newRow.substring(5, 7), 'ok');
      overlay.dispose();
    });

    test('extra rows from previous show are erased', () {
      final overlay = OverlayRegion(
        screen,
        const Rect(row: 10, col: 5, width: 20, height: 3),
      );
      overlay.show(['a', 'b', 'c']);
      overlay.show(['only-line']);
      vt.feed(io.written.toString());
      // Row 10 has new content.
      expect(vt.rowText(10).substring(5, 14), 'only-line');
      // Rows 11 and 12 erased.
      expect(vt.rowText(11).substring(5, 25).trim(), isEmpty);
      expect(vt.rowText(12).substring(5, 25).trim(), isEmpty);
      overlay.dispose();
    });

    test('clips bounds to screen', () {
      // Position partially off the bottom — should clip to fit.
      final overlay = OverlayRegion(
        screen,
        const Rect(row: 22, col: 5, width: 10, height: 5),
      );
      // Bounds are clipped so we don't write into the bottom border row.
      expect(overlay.bounds.bottom <= layout.height - 1, isTrue);
      overlay.dispose();
    });
  });
}
