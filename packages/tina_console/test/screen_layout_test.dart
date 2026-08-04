import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

void main() {
  group('ScreenLayout', () {
    test('narrow terminal has chat box only (no info panel)', () {
      final l = ScreenLayout.fromSize(80, 24);
      expect(l.isSplit, isFalse);
      expect(l.info.isEmpty, isTrue);
      // Chat box spans full width; content interior is width-2 (borders).
      expect(l.chat.col, 1);
      expect(l.chat.width, 78);
      // Input lives inside the chat box, just above the bottom border.
      expect(l.input.row, 22);
      expect(l.bottomBorderRow, 23);
    });

    test('wide terminal splits chat + info', () {
      final l = ScreenLayout.fromSize(100, 24);
      expect(l.isSplit, isTrue);
      // Chat width ~= round(100 * 0.65) = 65; info gets the rest.
      expect(l.chatLeftCol, 0);
      expect(l.chatRightCol, 64);
      expect(l.infoLeftCol, 65);
      expect(l.infoRightCol, 99);
      // Chat interior (inside borders).
      expect(l.chat.col, 1);
      expect(l.chat.row, 1);
      expect(l.chat.width, 63);
      // Info interior.
      expect(l.info.col, 66);
      expect(l.info.width, 33);
      // Border rows.
      expect(l.topBorderRow, 0);
      expect(l.bottomBorderRow, 23);
      expect(l.input.row, 22);
    });

    test('border characters at the info box corners', () {
      final l = ScreenLayout.fromSize(120, 30);
      // The chat area's border is panel-drawn, so borderCharFor only describes
      // the info box now.
      expect(l.borderCharFor(0, l.infoLeftCol), '┌');
      expect(l.borderCharFor(0, l.infoRightCol), '┐');
      expect(l.borderCharFor(29, l.infoLeftCol), '└');
      expect(l.borderCharFor(29, l.infoRightCol), '┘');
      // Sides inside the box height.
      expect(l.borderCharFor(5, l.infoRightCol), '│');
      // Chat-area columns are no longer Screen borders.
      expect(l.borderCharFor(0, l.chatLeftCol), isNull);
      expect(l.borderCharFor(5, l.chatLeftCol), isNull);
      expect(l.borderCharFor(5, l.infoLeftCol), '│');
      // Nothing in the interior.
      expect(l.borderCharFor(5, 10), isNull);
      // Separator row is gone — no ├/┤/┼/┬/┴ anywhere.
      for (var r = 0; r < 30; r++) {
        for (final ch in ['├', '┤', '┼', '┬', '┴']) {
          for (var c = 0; c < 120; c++) {
            expect(l.borderCharFor(r, c), isNot(equals(ch)),
                reason: 'no dividers or separators in the new layout');
          }
        }
      }
    });

    test('non-split layout has no Screen-painted borders (chat is panel-drawn)', () {
      final l = ScreenLayout.fromSize(80, 24);
      // No info panel, and the chat border is panel-drawn — borderCharFor is
      // null at the screen edges.
      expect(l.isSplit, isFalse);
      expect(l.infoLeftCol, -1);
      expect(l.borderCharFor(0, 0), isNull);
      expect(l.borderCharFor(23, 79), isNull);
    });

    test('clamps very small terminals to a usable minimum', () {
      final l = ScreenLayout.fromSize(40, 2);
      expect(l.height, greaterThanOrEqualTo(5));
    });

    test('hasMenuBar=false (default) has no menu bar row', () {
      final l = ScreenLayout.fromSize(100, 24);
      expect(l.hasMenuBar, isFalse);
      expect(l.menuBarRow, -1);
    });

    test('menu box shifts the whole frame down by three rows', () {
      final l = ScreenLayout.fromSize(100, 24, hasMenuBar: true);
      expect(l.hasMenuBar, isTrue);
      expect(l.menuBarRow, 1); // content row inside the 3-row box
      expect(l.menuTopBorderRow, 0);
      expect(l.menuBottomBorderRow, 2);
      expect(l.topBorderRow, 3); // chat/info top border below the menu box
      expect(l.chat.row, 4);
      expect(l.info.row, 4);
      final noBar = ScreenLayout.fromSize(100, 24);
      // Content areas lose three rows to make room for the menu box.
      expect(l.chat.height, noBar.chat.height - 3);
      expect(l.info.height, noBar.info.height - 3);
      // Input and bottom border stay at the same absolute rows.
      expect(l.input.row, noBar.input.row);
      expect(l.bottomBorderRow, noBar.bottomBorderRow);
    });

    test('menu box has bordered characters on its three rows', () {
      final l = ScreenLayout.fromSize(100, 24, hasMenuBar: true);
      // Top border row (0): corners + horizontal rule.
      expect(l.borderCharFor(0, 0), '┌');
      expect(l.borderCharFor(0, l.rightBorderCol), '┐');
      expect(l.borderCharFor(0, l.chatRightCol), '─');
      // Content row (1): only the side borders; interior is null (labels).
      expect(l.borderCharFor(1, 0), '│');
      expect(l.borderCharFor(1, l.rightBorderCol), '│');
      expect(l.borderCharFor(1, 10), isNull);
      // Bottom border row (2): corners.
      expect(l.borderCharFor(2, 0), '└');
      expect(l.borderCharFor(2, l.rightBorderCol), '┘');
      // The chat area's top border (row 3) is panel-drawn, not a Screen border.
      expect(l.borderCharFor(3, l.chatLeftCol), isNull);
      expect(l.borderCharFor(3, l.chatRightCol), isNull);
    });

    test('narrow terminal with menu box shifts chat down', () {
      final l = ScreenLayout.fromSize(80, 24, hasMenuBar: true);
      expect(l.isSplit, isFalse);
      expect(l.hasMenuBar, isTrue);
      expect(l.menuBarRow, 1);
      // Chat interior starts at row 4 (rows 0–2 = menu box, row 3 = top border).
      expect(l.chat.row, 4);
      // Input row still just above the bottom border.
      expect(l.input.row, 22);
    });
  });
}
