import 'package:tina_layout/tina_layout.dart';
import 'package:test/test.dart';

void main() {
  group('aspect hints', () {
    GridSolution overlay({
      required double aspectHint,
      double? maxHeightUnits,
      double trackMinUnits = 0,
    }) =>
        GridSolver.solve(
          GridSpec(
            columns: const [
              GridTrack.weighted(3),
              GridTrack.weighted(2, minUnits: 24, maxUnits: 64),
            ],
            rows: [
              GridTrack.auto(minUnits: trackMinUnits),
            ],
            items: [
              GridItem(
                id: 'panel',
                column: const TrackSpan.at(1),
                row: const TrackSpan.at(0),
                aspectHint: aspectHint,
                maxHeightUnits: maxHeightUnits,
              ),
            ],
          ),
          columns: 120,
          rows: 24,
        );

    test('square image gets a visually square panel', () {
      // 120 cols: panel column = 48. A square image at 2:1 cells has unit
      // aspect 4 -> height 48/4 = 12 units = 24 rows.
      final s = overlay(aspectHint: 4);
      expect(s.columnTrackSizes[1], 48);
      expect(s.rowTrackSizes, [12]);
      expect(s.rectOf('panel'),
          const GridRect(col: 72, row: 0, width: 48, height: 24));
      expect(s.hasOverflow, isFalse);
    });

    test('wide image gets a short panel; unused space is trailing gap', () {
      final s = overlay(aspectHint: 8);
      expect(s.rowTrackSizes, [6]);
      expect(s.rectOf('panel')!.height, 12);
      expect(s.trailingGapUnitsY, 6);
    });

    test('item max height caps the aspect-derived size', () {
      final s = overlay(aspectHint: 4, maxHeightUnits: 5);
      expect(s.rowTrackSizes, [5]);
      expect(s.rectOf('panel')!.height, 10);
    });

    test('track minimum floors the aspect-derived size', () {
      final s = overlay(aspectHint: 16, trackMinUnits: 4);
      expect(s.rowTrackSizes, [4]);
    });

    test('aspectFromPixels maps pixel ratios to unit ratios', () {
      const m = CellMetrics.standard;
      expect(m.aspectFromPixels(100, 100), 4.0); // square in pixels
      expect(m.aspectFromPixels(200, 100), 8.0);
      expect(m.aspectFromPixels(100, 200), 2.0);
      // Square cells: unit aspect equals pixel aspect.
      final square = CellMetrics.fromPixels(cellWidthPx: 8, cellHeightPx: 8);
      expect(square.aspectFromPixels(200, 100), 2.0);
    });
  });

  group('hit testing', () {
    test('overlapping rects resolve to the later item (topmost)', () {
      final s = GridSolver.solve(
        const GridSpec(
          columns: [GridTrack.weighted(1), GridTrack.fixed(10)],
          rows: [GridTrack.weighted(1)],
          items: [
            GridItem(
                id: 'back',
                column: TrackSpan.at(0, span: 2),
                row: TrackSpan.at(0)),
            GridItem(id: 'overlay', column: TrackSpan.at(1), row: TrackSpan.at(0)),
          ],
        ),
        columns: 40,
        rows: 10,
      );
      expect(s.hitTest(0, 0), 'back');
      expect(s.hitTest(30, 0), 'overlay');
      expect(s.hitTest(39, 9), 'overlay');
      expect(s.hitTest(40, 0), isNull, reason: 'outside the terminal');
    });

    test('exact cell math on boundaries', () {
      final s = GridSolver.solve(
        const GridSpec(
          columns: [GridTrack.fixed(5), GridTrack.weighted(1)],
          rows: [GridTrack.weighted(1)],
          items: [
            GridItem(id: 'left', column: TrackSpan.at(0), row: TrackSpan.at(0)),
            GridItem(id: 'right', column: TrackSpan.at(1), row: TrackSpan.at(0)),
          ],
        ),
        columns: 10,
        rows: 2,
      );
      expect(s.hitTest(4, 0), 'left');
      expect(s.hitTest(5, 1), 'right');
      expect(s.hitTest(10, 0), isNull);
      expect(s.hitTest(0, 2), isNull);
    });
  });
}
