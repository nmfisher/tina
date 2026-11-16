import 'package:tina_layout/tina_layout.dart';
import 'package:test/test.dart';

void main() {
  // A sidebar + flexible body, header + flexible list + footer: the shape of
  // a chat screen, exercised across resize sequences.
  const spec = GridSpec(
    columns: [
      GridTrack.fixed(3, minUnits: 3),
      GridTrack.weighted(1),
    ],
    rows: [
      GridTrack.fixed(0.5),
      GridTrack.weighted(1),
      GridTrack.fixed(0.5),
    ],
    items: [
      GridItem(
          id: 'sidebar',
          column: const TrackSpan.at(0),
          row: const TrackSpan.at(0, span: 3)),
      GridItem(id: 'header', column: TrackSpan.at(1), row: TrackSpan.at(0)),
      GridItem(id: 'body', column: TrackSpan.at(1), row: TrackSpan.at(1)),
      GridItem(id: 'footer', column: TrackSpan.at(1), row: TrackSpan.at(2)),
    ],
  );

  GridSolution at(int columns, int rows) =>
      GridSolver.solve(spec, columns: columns, rows: rows);

  group('resize sequences', () {
    test('shrinking and growing keeps the top/left anchors stable', () {
      final sizes = [
        (80, 24),
        (40, 24),
        (40, 12),
        (16, 12),
        (120, 40),
        (80, 24),
      ];
      for (final (w, h) in sizes) {
        final s = at(w, h);
        expect(s.rectOf('sidebar')!.col, 0, reason: '$w x $h');
        expect(s.rectOf('sidebar')!.width, 3, reason: '$w x $h');
        expect(s.rectOf('header')!.col, 3, reason: '$w x $h');
        expect(s.rectOf('header')!.row, 0, reason: '$w x $h');
        expect(s.rectOf('header')!.height, 1, reason: '$w x $h');
        expect(s.rectOf('footer')!.row, h - 1, reason: '$w x $h footer pinned');
        expect(s.rectOf('footer')!.width, w - 3, reason: '$w x $h');
        expect(s.rectOf('body')!.row, 1, reason: '$w x $h');
        expect(s.rectOf('body')!.height, h - 2, reason: '$w x $h');
        expect(s.rectOf('body')!.width, w - 3, reason: '$w x $h');
      }
    });

    test('same size always solves identically (purity)', () {
      final a = at(97, 31);
      final b = at(97, 31);
      expect(a.rects, equals(b.rects));
      expect(a.columnTrackSizes, equals(b.columnTrackSizes));
      expect(a.rowTrackSizes, equals(b.rowTrackSizes));
    });

    test('invariants across a resize sweep', () {
      for (var w = 0; w <= 130; w += 7) {
        for (var h = 0; h <= 40; h += 5) {
          final s = at(w, h);
          for (final rect in s.rects.values) {
            expect(rect.col, greaterThanOrEqualTo(0));
            expect(rect.row, greaterThanOrEqualTo(0));
            expect(rect.width, greaterThanOrEqualTo(0));
            expect(rect.height, greaterThanOrEqualTo(0));
            expect(rect.col + rect.width, lessThanOrEqualTo(w),
                reason: '$w x $h ${s.rects}');
            expect(rect.row + rect.height, lessThanOrEqualTo(h),
                reason: '$w x $h ${s.rects}');
          }
        }
      }
    });
  });
}
