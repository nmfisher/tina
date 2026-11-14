import 'package:tina_layout/tina_layout.dart';
import 'package:test/test.dart';

void main() {
  group('overflow policy', () {
    test('drops lowest-priority contributors until the minimums fit', () {
      final s = GridSolver.solve(
        GridSpec(
          columns: const [
            GridTrack.auto(),
            GridTrack.auto(),
            GridTrack.auto(),
          ],
          rows: const [GridTrack.weighted(1)],
          items: const [
            GridItem(
                id: 'chat',
                priority: 2,
                minWidthUnits: 6,
                column: TrackSpan.at(0),
                row: TrackSpan.at(0)),
            GridItem(
                id: 'p1',
                priority: 1,
                minWidthUnits: 6,
                column: TrackSpan.at(1),
                row: TrackSpan.at(0)),
            GridItem(
                id: 'p0',
                priority: 0,
                minWidthUnits: 6,
                column: TrackSpan.at(2),
                row: TrackSpan.at(0)),
          ],
        ),
        columns: 10,
        rows: 10,
      );
      expect(s.dropped.map((d) => d.id), ['p0', 'p1']);
      expect(s.dropped.map((d) => d.reason), everyElement('overflow'));
      expect(s.rects.keys, ['chat']);
      expect(s.hasOverflow, isFalse);
    });

    test('priority ties drop the later-declared item first', () {
      final s = GridSolver.solve(
        GridSpec(
          columns: const [GridTrack.auto(), GridTrack.auto()],
          rows: const [GridTrack.weighted(1)],
          items: const [
            GridItem(
                id: 'first',
                minWidthUnits: 6,
                column: TrackSpan.at(0),
                row: TrackSpan.at(0)),
            GridItem(
                id: 'second',
                minWidthUnits: 6,
                column: TrackSpan.at(1),
                row: TrackSpan.at(0)),
          ],
        ),
        columns: 7,
        rows: 10,
      );
      expect(s.dropped.map((d) => d.id), ['second']);
      expect(s.rects.keys, ['first']);
    });

    test('higher priority survives equal-min competitors', () {
      final s = GridSolver.solve(
        GridSpec(
          columns: const [GridTrack.auto(), GridTrack.auto()],
          rows: const [GridTrack.weighted(1)],
          items: const [
            GridItem(
                id: 'low',
                priority: 1,
                minWidthUnits: 6,
                column: TrackSpan.at(0),
                row: TrackSpan.at(0)),
            GridItem(
                id: 'high',
                priority: 5,
                minWidthUnits: 6,
                column: TrackSpan.at(1),
                row: TrackSpan.at(0)),
          ],
        ),
        columns: 7,
        rows: 10,
      );
      expect(s.dropped.map((d) => d.id), ['low']);
      expect(s.rects.keys, ['high']);
    });

    test('template minimums that cannot fit report overflow without drops',
        () {
      final s = GridSolver.solve(
        GridSpec(
          columns: const [GridTrack.fixed(30)],
          rows: const [GridTrack.fixed(10)],
          items: const [
            GridItem(id: 'a', column: TrackSpan.at(0), row: TrackSpan.at(0)),
          ],
        ),
        columns: 10,
        rows: 4,
      );
      // No item contributes a minimum, so nothing is dropped; the axis
      // reports the deficit and rects are truncated to the terminal.
      expect(s.dropped, isEmpty);
      expect(s.overflowUnitsX, 20);
      expect(s.overflowUnitsY, 8);
      expect(s.rectOf('a'), const GridRect(col: 0, row: 0, width: 10, height: 4));
    });
  });

  group('degenerate terminals', () {
    const spec = GridSpec(
      columns: [GridTrack.fixed(1), GridTrack.weighted(1)],
      rows: [GridTrack.fixed(0.5), GridTrack.weighted(1)],
      items: [GridItem(id: 'only', column: TrackSpan.at(1), row: TrackSpan.at(1))],
    );

    test('zero-size terminal produces empty rects and no crash', () {
      final s = GridSolver.solve(spec, columns: 0, rows: 0);
      expect(s.rectOf('only'), GridRect.empty);
      expect(s.hitTest(0, 0), isNull);
      expect(s.hasOverflow, isTrue);
    });

    test('1x1 terminal never emits negative rects', () {
      final s = GridSolver.solve(spec, columns: 1, rows: 1);
      for (final rect in s.rects.values) {
        expect(rect.width, greaterThanOrEqualTo(0));
        expect(rect.height, greaterThanOrEqualTo(0));
      }
      expect(s.rectOf('only'), GridRect.empty);
    });

    test('empty template drops all items with no-tracks', () {
      final s = GridSolver.solve(
          const GridSpec(columns: [], rows: [], items: [
            GridItem(id: 'x'),
          ]),
          columns: 80,
          rows: 24);
      expect(s.dropped.map((d) => d.reason), ['no-tracks']);
      expect(s.rects, isEmpty);
    });
  });
}
