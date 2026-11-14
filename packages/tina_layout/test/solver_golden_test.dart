import 'package:tina_layout/tina_layout.dart';
import 'package:test/test.dart';

void main() {
  group('weighted column split (65/35 with minimums)', () {
    GridSolution split(int width) => GridSolver.solve(
          GridSpec(
            columns: const [
              GridTrack.weighted(65, minUnits: 30),
              GridTrack.weighted(35, minUnits: 20),
            ],
            rows: const [GridTrack.weighted(1)],
            items: const [
              GridItem(
                  id: 'chat',
                  column: TrackSpan.at(0),
                  row: TrackSpan.at(0)),
              GridItem(
                  id: 'info',
                  column: TrackSpan.at(1),
                  row: TrackSpan.at(0)),
            ],
          ),
          columns: width,
          rows: 24,
        );

    test('exact split at 100 and 120 columns', () {
      expect(split(100).columnTrackSizes, [65, 35]);
      expect(split(120).columnTrackSizes, [78, 42]);
      expect(split(100).rectOf('chat'), const GridRect(col: 0, row: 0, width: 65, height: 24));
      expect(split(100).rectOf('info'), const GridRect(col: 65, row: 0, width: 35, height: 24));
    });

    test('largest-remainder rounding, ties to the earlier track', () {
      // 110 * 0.65 = 71.5, 110 * 0.35 = 38.5: floors 71/38, one extra unit,
      // fractional tie -> earlier track. (Matches Dart round() on 71.5.)
      expect(split(110).columnTrackSizes, [72, 38]);
      // 107: 69.55 / 37.45 -> 70 / 37, no tie.
      expect(split(107).columnTrackSizes, [70, 37]);
    });

    test('minimums steal surplus from the larger track', () {
      // 50: ideals 33/17 after rounding; info min 20 -> chat gives 3.
      expect(split(50).columnTrackSizes, [30, 20]);
      // 55: ideals 36/19; info min 20 -> chat 35.
      expect(split(55).columnTrackSizes, [35, 20]);
      expect(split(50).hasOverflow, isFalse);
    });

    test('full span is always covered exactly when minimums fit', () {
      for (final w in [50, 55, 58, 60, 99, 100, 101, 110, 120, 200]) {
        final sizes = split(w).columnTrackSizes;
        final total = sizes.fold<double>(0, (a, b) => a + b);
        expect(total, w, reason: 'width $w leaves no gap');
      }
    });
  });

  group('half-unit rows reproduce the chat stack', () {
    GridSolution stack(int height) => GridSolver.solve(
          GridSpec(
            columns: const [GridTrack.weighted(1)],
            rows: const [
              GridTrack.fixed(0.5), // box top border
              GridTrack.weighted(1), // transcript
              GridTrack.fixed(0.5), // input row
              GridTrack.fixed(0.5), // box bottom border
              GridTrack.fixed(0.5), // status strip
            ],
            items: const [
              GridItem(id: 'top', column: TrackSpan.at(0), row: TrackSpan.at(0)),
              GridItem(
                  id: 'transcript',
                  column: TrackSpan.at(0),
                  row: TrackSpan.at(1)),
              GridItem(id: 'input', column: TrackSpan.at(0), row: TrackSpan.at(2)),
              GridItem(id: 'bottom', column: TrackSpan.at(0), row: TrackSpan.at(3)),
              GridItem(id: 'strip', column: TrackSpan.at(0), row: TrackSpan.at(4)),
            ],
          ),
          columns: 80,
          rows: height,
        );

    test('even height: 24 rows', () {
      final s = stack(24);
      expect(s.rowTrackSizes, [0.5, 10, 0.5, 0.5, 0.5]);
      expect(s.rectOf('top'), const GridRect(col: 0, row: 0, width: 80, height: 1));
      expect(s.rectOf('transcript'),
          const GridRect(col: 0, row: 1, width: 80, height: 20));
      expect(s.rectOf('input'),
          const GridRect(col: 0, row: 21, width: 80, height: 1));
      expect(s.rectOf('bottom'),
          const GridRect(col: 0, row: 22, width: 80, height: 1));
      expect(s.rectOf('strip'),
          const GridRect(col: 0, row: 23, width: 80, height: 1));
    });

    test('odd height: 25 rows gives the flexible track the extra row', () {
      final s = stack(25);
      expect(s.rowTrackSizes, [0.5, 10.5, 0.5, 0.5, 0.5]);
      expect(s.rectOf('transcript')!.height, 21);
      expect(s.rectOf('strip')!.row, 24);
    });

    test('tiny heights collapse the flexible track, never the fixed ones',
        () {
      // 4 rows = 2 units: fixed minimums alone need 2 units.
      final s = stack(4);
      expect(s.hasOverflow, isFalse);
      expect(s.rectOf('transcript')!.height, 0);
      expect(s.rectOf('strip')!.row, 3);
    });
  });

  group('auto tracks size from content minimums', () {
    test('single-span items', () {
      final s = GridSolver.solve(
        GridSpec(
          columns: const [GridTrack.auto(), GridTrack.auto()],
          rows: const [GridTrack.weighted(1)],
          items: const [
            GridItem(
                id: 'a',
                minWidthUnits: 10,
                column: TrackSpan.at(0),
                row: TrackSpan.at(0)),
            GridItem(
                id: 'b',
                minWidthUnits: 5,
                column: TrackSpan.at(1),
                row: TrackSpan.at(0)),
          ],
        ),
        columns: 40,
        rows: 10,
      );
      expect(s.columnTrackSizes, [10, 5]);
      expect(s.trailingGapUnitsX, 25);
      expect(s.rectOf('a')!.width, 10);
    });

    test('item minimums are clamped by the item maximum', () {
      final s = GridSolver.solve(
        GridSpec(
          columns: const [GridTrack.auto()],
          rows: const [GridTrack.weighted(1)],
          items: const [
            GridItem(
                id: 'a',
                minWidthUnits: 30,
                maxWidthUnits: 12,
                column: TrackSpan.at(0),
                row: TrackSpan.at(0)),
          ],
        ),
        columns: 40,
        rows: 10,
      );
      expect(s.columnTrackSizes, [12]);
    });

    test('spanning item spreads its minimum over covered auto tracks', () {
      final s = GridSolver.solve(
        GridSpec(
          columns: const [GridTrack.auto(), GridTrack.auto()],
          rows: const [GridTrack.weighted(1)],
          items: const [
            GridItem(
                id: 'a',
                minWidthUnits: 2,
                column: TrackSpan.at(0),
                row: TrackSpan.at(0)),
            GridItem(
                id: 'wide',
                minWidthUnits: 16,
                column: TrackSpan.at(0, span: 2),
                row: TrackSpan.at(0)),
          ],
        ),
        columns: 40,
        rows: 10,
      );
      // Covered starts at 2; the 14-unit deficit splits 7/7 over the autos.
      expect(s.columnTrackSizes, [9, 7]);
    });

    test('track minimum is a floor even without items', () {
      final s = GridSolver.solve(
        GridSpec(
          columns: const [GridTrack.auto(minUnits: 8), GridTrack.weighted(1)],
          rows: const [GridTrack.weighted(1)],
          items: const [
            GridItem(
                id: 'body',
                column: TrackSpan.at(1),
                row: TrackSpan.at(0)),
          ],
        ),
        columns: 20,
        rows: 10,
      );
      expect(s.columnTrackSizes, [8, 12]);
    });
  });

  group('fixed tracks and clamps', () {
    test('fixed size clamped to [min, max]', () {
      final s = GridSolver.solve(
        GridSpec(
          columns: const [
            GridTrack.fixed(5, minUnits: 2, maxUnits: 4),
            GridTrack.fixed(1, minUnits: 3),
            GridTrack.weighted(1),
          ],
          rows: const [GridTrack.weighted(1)],
          items: const [
            GridItem(id: 'rest', column: TrackSpan.at(2), row: TrackSpan.at(0)),
          ],
        ),
        columns: 20,
        rows: 10,
      );
      // 5 clamps down to max 4; 1 raises to min 3; weighted gets 13.
      expect(s.columnTrackSizes, [4, 3, 13]);
    });

    test('weighted max lowers a track and gives the excess away', () {
      final s = GridSolver.solve(
        GridSpec(
          columns: const [
            GridTrack.weighted(1),
            GridTrack.weighted(1, maxUnits: 10),
          ],
          rows: const [GridTrack.weighted(1)],
          items: const [
            GridItem(id: 'a', column: TrackSpan.at(0), row: TrackSpan.at(0)),
            GridItem(id: 'b', column: TrackSpan.at(1), row: TrackSpan.at(0)),
          ],
        ),
        columns: 40,
        rows: 10,
      );
      expect(s.columnTrackSizes, [30, 10]);
    });
  });

  group('cell space conversions', () {
    test('units map 1:1 to columns', () {
      final s = GridSolver.solve(
        GridSpec(
          columns: const [
            GridTrack.fixed(3),
            GridTrack.fixed(0.25), // snaps to 0 columns wide
            GridTrack.weighted(1),
          ],
          rows: const [GridTrack.weighted(1)],
          items: const [
            GridItem(id: 'body', column: TrackSpan.at(2), row: TrackSpan.at(0)),
          ],
        ),
        columns: 10,
        rows: 2,
      );
      // The 0.25 track contributes no cells but shifts nothing: body still
      // starts at column 3 (3 and 3.25 both snap to 3) and fills the rest.
      expect(s.rectOf('body'),
          const GridRect(col: 3, row: 0, width: 7, height: 2));
    });

    test('non-standard metrics scale rows per unit', () {
      // Square cells: one unit = one row.
      final s = GridSolver.solve(
        GridSpec(
          columns: const [GridTrack.weighted(1)],
          rows: const [
            GridTrack.fixed(1),
            GridTrack.weighted(1),
            GridTrack.fixed(1),
          ],
          items: const [
            GridItem(id: 'mid', column: TrackSpan.at(0), row: TrackSpan.at(1)),
          ],
        ),
        columns: 10,
        rows: 7,
        metrics: CellMetrics.fromPixels(cellWidthPx: 8, cellHeightPx: 8),
      );
      expect(s.rectOf('mid'), const GridRect(col: 0, row: 1, width: 10, height: 5));
    });
  });
}
