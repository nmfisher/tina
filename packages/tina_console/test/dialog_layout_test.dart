import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';

void main() {
  test(
      'preferred dialog dimensions are centered and constrained by the viewport',
      () {
    for (final (width, height) in [(160, 40), (40, 8), (1, 1), (0, 0)]) {
      final layout = ScreenLayout.fromSize(width, height, split: false);
      final area = dialogArea(layout);
      final bounds =
          dialogBounds(layout, preferredWidth: 88, preferredHeight: 24);
      expect(bounds.width, 88.clamp(0, area.width));
      expect(bounds.height, 24.clamp(0, area.height));
      expect(bounds.row, area.row + (area.height - bounds.height) ~/ 2);
      expect(bounds.col, area.col + (area.width - bounds.width) ~/ 2);
      expect(bounds.right, lessThanOrEqualTo(area.right));
      expect(bounds.bottom, lessThanOrEqualTo(area.bottom));
    }
  });
}
