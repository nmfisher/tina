import 'package:tina_layout/tina_layout.dart';
import 'package:test/test.dart';

void main() {
  group('auto-flow placement', () {
    test('row-major first-fit with a sparse cursor', () {
      final s = GridSolver.solve(
        const GridSpec(
          columns: [
            GridTrack.weighted(1),
            GridTrack.weighted(1),
          ],
          rows: [
            GridTrack.weighted(1),
            GridTrack.weighted(1),
          ],
          items: [
            GridItem(id: 'a'), // 1x1
            GridItem(id: 'b', column: TrackSpan.span(2)), // needs 2 cols
            GridItem(id: 'c'), // no room left
          ],
        ),
        columns: 20,
        rows: 20,
      );
      expect(s.rectOf('a'), const GridRect(col: 0, row: 0, width: 10, height: 10));
      // b cannot fit at (row 0, col 1): wraps to row 1, columns 0-1.
      expect(s.rectOf('b'), const GridRect(col: 0, row: 10, width: 20, height: 10));
      expect(s.dropped.map((d) => d.id), ['c']);
      expect(s.dropped.first.reason, 'no-room');
    });

    test('explicit items reserve cells before auto items', () {
      final s = GridSolver.solve(
        const GridSpec(
          columns: [
            GridTrack.weighted(1),
            GridTrack.weighted(1),
          ],
          rows: [
            GridTrack.weighted(1),
          ],
          items: [
            GridItem(id: 'fixed', column: TrackSpan.at(0), row: TrackSpan.at(0)),
            GridItem(id: 'flowed'), // skips the occupied cell
          ],
        ),
        columns: 20,
        rows: 10,
      );
      expect(s.rectOf('fixed'), const GridRect(col: 0, row: 0, width: 10, height: 10));
      expect(s.rectOf('flowed'), const GridRect(col: 10, row: 0, width: 10, height: 10));
    });

    test('locked column with auto row scans the free axis', () {
      final s = GridSolver.solve(
        const GridSpec(
          columns: [
            GridTrack.weighted(1),
            GridTrack.weighted(1),
          ],
          rows: [
            GridTrack.fixed(0.5),
            GridTrack.weighted(1),
          ],
          items: [
            GridItem(id: 'header', column: TrackSpan.at(1), row: TrackSpan.at(0)),
            GridItem(id: 'below', column: TrackSpan.at(1), row: TrackSpan.auto()),
          ],
        ),
        columns: 20,
        rows: 10,
      );
      expect(s.rectOf('below'), const GridRect(col: 10, row: 1, width: 10, height: 9));
    });

    test('spans are clamped into the template', () {
      final s = GridSolver.solve(
        const GridSpec(
          columns: [GridTrack.weighted(1)],
          rows: [GridTrack.weighted(1)],
          items: [
            GridItem(
                id: 'big',
                column: TrackSpan.at(0, span: 9),
                row: TrackSpan.at(7, span: 4)),
          ],
        ),
        columns: 40,
        rows: 10,
      );
      expect(s.rectOf('big'), const GridRect(col: 0, row: 0, width: 40, height: 10));
    });
  });

  group('CellMetrics', () {
    test('fromPixels reduces to rows per unit', () {
      expect(CellMetrics.fromPixels(cellWidthPx: 10, cellHeightPx: 20).rowsPerUnit, 2.0);
      expect(CellMetrics.fromPixels(cellWidthPx: 8, cellHeightPx: 12).rowsPerUnit, 1.5);
    });

    test('rejects non-positive cells', () {
      expect(() => CellMetrics.fromPixels(cellWidthPx: 0, cellHeightPx: 20),
          throwsArgumentError);
      expect(() => CellMetrics.fromPixels(cellWidthPx: 10, cellHeightPx: -1),
          throwsArgumentError);
    });

    test('unit/row conversions', () {
      const m = CellMetrics.standard;
      expect(m.unitsToRows(1.5), 3.0);
      expect(m.rowsToUnits(7), 3.5);
      expect(m.snapRow(5.75), 12); // 5.75 units * 2 rows/unit = 11.5 -> 12
      expect(m.snapColumn(2.5), 3);
    });
  });
}
