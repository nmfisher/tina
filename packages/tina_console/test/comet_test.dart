import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

/// Pure tests for the comet cell math ([cometCellFor] / [cometHeadOffset] /
/// [cometRailCells]) that the panel busy animation is built on. The panel-level
/// sweep is covered in `conversation_panel_test.dart`.
void main() {
  /// Parse `38;2;r;g;b` out of an SGR code (with an optional leading `1;`).
  List<int> rgbOf(String code) {
    final m = RegExp(r'38;2;(\d+);(\d+);(\d+)').firstMatch(code)!;
    return [int.parse(m[1]!), int.parse(m[2]!), int.parse(m[3]!)];
  }

  group('cometCellFor', () {
    test('the head is a bold bright-cyan heavy glyph; ahead/behind-far is rail', () {
      const theme = Theme();
      final head = cometCellFor(theme, 0);
      expect(head.glyph, '━');
      expect(head.code, startsWith('1;38;2;'));

      // Ahead of the head, or beyond the tail: plain rail cell, no color.
      final ahead = cometCellFor(theme, -1);
      expect(ahead.glyph, '─');
      expect(ahead.code, isNull);
      final far = cometCellFor(theme, 100);
      expect(far.glyph, '─');
      expect(far.code, isNull);
    });

    test('the tail fades truecolor toward the rail and ends in a rail cell', () {
      const theme = Theme();
      // Tail cells are light `─` with their own truecolor code, fading from the
      // head's bright cyan toward the rail RGB [30,110,130].
      final near = cometCellFor(theme, 1);
      expect(near.glyph, '─');
      expect(near.code, isNotNull);
      expect(near.code, startsWith('38;2;'));

      final rgbNear = rgbOf(near.code!);
      expect(rgbNear[0], greaterThan(30), reason: 'near-tail R brighter than rail');

      // Once past the tail length the cell is plain rail again.
      expect(cometCellFor(theme, 8).code, isNull);
    });
  });

  group('cometHeadOffset', () {
    test('advances one cell per tick and wraps at the span', () {
      expect(cometHeadOffset(10, 0), 0);
      expect(cometHeadOffset(10, 1), 1);
      expect(cometHeadOffset(10, 9), 9);
      expect(cometHeadOffset(10, 10), 0); // wraps
    });

    test('shift offsets the top rail by half the span', () {
      // shift=true offsets by n~/2 so top and bottom sweep opposite sides.
      expect(cometHeadOffset(10, 0, shift: true), 5);
      expect(cometHeadOffset(10, 1, shift: true), 6);
    });

    test('a sub-1 span clamps to 1 (no division by zero)', () {
      expect(cometHeadOffset(0, 5), 0);
      expect(cometHeadOffset(-3, 5, shift: true), 0);
    });
  });

  group('cometRailCells', () {
    test('places the head at the offset with the tail trailing behind', () {
      const theme = Theme();
      final cells = cometRailCells(theme, 5, 0); // head at offset 0
      expect(cells[0].glyph, '━'); // head
      expect(cells[0].code, startsWith('1;38;2;'));
      for (var i = 1; i < 5; i++) {
        expect(cells[i].glyph, '─'); // tail
      }
    });
  });
}
