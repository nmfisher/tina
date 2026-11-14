import 'package:tina_layout/tina_layout.dart';
import 'package:test/test.dart';

/// Goldens for the image-overlay grid tina_chat_tui lays its floating image
/// panels into: a right-anchored column over the chat box, one stacked auto
/// row track per panel, each sized from its image's aspect hint. This is
/// the contract the panels workspace consumes; the wiring is a thin
/// rect->PanelFrame.setOuter mapping.
void main() {
  const metrics = CellMetrics.standard;

  GridSolution overlay({
    required int chatBoxWidth,
    required int bodyRows,
    required List<({int px, int py})> images,
  }) {
    final count = images.length;
    final shareUnits = metrics.rowsToUnits(bodyRows - 1) / count;
    return GridSolver.solve(
        GridSpec(
            columns: const [
              GridTrack.weighted(3),
              GridTrack.weighted(2, minUnits: 24, maxUnits: 64),
            ],
            rows: [
              const GridTrack.fixed(0.5), // chat box top border row
              for (var i = 0; i < count; i++) const GridTrack.auto(minUnits: 3),
            ],
            items: [
              for (var i = 0; i < count; i++)
                GridItem(
                  id: 'panel$i',
                  column: const TrackSpan.at(1),
                  row: TrackSpan.at(i + 1),
                  minWidthUnits: 24,
                  minHeightUnits: 3,
                  maxHeightUnits: shareUnits,
                  aspectHint:
                      metrics.aspectFromPixels(images[i].px, images[i].py),
                  priority: i,
                ),
            ]),
        columns: chatBoxWidth,
        rows: bodyRows,
        metrics: metrics);
  }

  test('single square image fills its share, right-anchored at 40%', () {
    final s = overlay(chatBoxWidth: 120, bodyRows: 22, images: [
      (px: 28, py: 28),
    ]);
    final rect = s.rectOf('panel0')!;
    // Two fifths of 120 = 48 columns, flush right.
    expect(rect.col, 72);
    expect(rect.width, 48);
    // Square image: unit aspect 4 -> 48/4 = 12 units, capped by the body
    // share ((22-1)/2 = 10.5 units) -> 21 rows starting below the border.
    expect(rect.row, 1);
    expect(rect.height, 21);
    expect(s.dropped, isEmpty);
  });

  test('two wide screenshots stack without overlapping', () {
    final s = overlay(chatBoxWidth: 120, bodyRows: 22, images: [
      (px: 1600, py: 900),
      (px: 1600, py: 900),
    ]);
    final a = s.rectOf('panel0')!;
    final b = s.rectOf('panel1')!;
    expect(a.col, 72);
    expect(a.width, 48);
    // 16:9 at 2:1 cells -> unit aspect 64/9; height 48/(64/9) = 6.75 units,
    // capped by each panel's 5.25-unit share; edges snap to whole rows.
    expect(a.row, 1);
    expect(b.row, greaterThanOrEqualTo(a.row + a.height));
    expect(b.row + b.height, lessThanOrEqualTo(22));
    expect(s.dropped, isEmpty);
  });

  test('tall portrait image is capped by its share, never the full body',
      () {
    final s = overlay(chatBoxWidth: 120, bodyRows: 22, images: [
      (px: 100, py: 900),
    ]);
    final rect = s.rectOf('panel0')!;
    expect(rect.height, 21); // share cap, not 48/aspectFromPixels(100,900)
    expect(rect.width, 48);
  });

  test('a narrow chat box drops panels rather than overflowing', () {
    // A 30-column chat box still fits the 24-column panel minimum...
    final narrow = overlay(chatBoxWidth: 30, bodyRows: 22, images: [
      (px: 28, py: 28),
    ]);
    expect(narrow.dropped, isEmpty);
    // ...but below it the minimum cannot be honored: the panel is dropped
    // with a report instead of rendering narrower than its floor.
    final tiny = overlay(chatBoxWidth: 16, bodyRows: 22, images: [
      (px: 28, py: 28),
    ]);
    expect(tiny.dropped.map((d) => d.id), ['panel0']);
    expect(tiny.dropped.first.reason, 'overflow');
  });

  test('a deep stack: the drop policy and static track minimums', () {
    // Within ONE solve the template is static: three 3-unit auto tracks
    // cannot fit a 5-unit body, and dropping items does not shrink the
    // empty tracks' declared minimums — so all three go. (Consumers that
    // rebuild the template per close, like the panels workspace's
    // close-and-relayout loop, shed panels incrementally instead.)
    final s = overlay(chatBoxWidth: 120, bodyRows: 10, images: [
      (px: 28, py: 28),
      (px: 28, py: 28),
      (px: 28, py: 28),
    ]);
    expect(s.dropped.map((d) => d.id), ['panel0', 'panel1', 'panel2']);
    expect(s.rects, isEmpty);
    // Two panels on a 13-row body fit 3-unit tracks exactly (border row +
    // 6 rows + 6 rows).
    final pair = overlay(chatBoxWidth: 120, bodyRows: 13, images: [
      (px: 28, py: 28),
      (px: 28, py: 28),
    ]);
    expect(pair.dropped, isEmpty);
    expect(pair.rectOf('panel0')!.height, 6);
    expect(pair.rectOf('panel1')!.height, 6);
  });
}
