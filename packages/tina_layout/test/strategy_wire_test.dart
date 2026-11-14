import 'package:tina_layout/tina_layout.dart';
import 'package:test/test.dart';

void main() {
  tearDown(LayoutStrategies.uninstall);

  const chatSpec = GridSpec(
    columns: [
      GridTrack.weighted(65, minUnits: 30),
      GridTrack.weighted(35, minUnits: 20),
    ],
    rows: [GridTrack.weighted(1)],
    items: [
      GridItem(id: 'chat', column: TrackSpan.at(0), row: TrackSpan.at(0)),
      GridItem(id: 'info', column: TrackSpan.at(1), row: TrackSpan.at(0)),
    ],
  );

  group('LayoutStrategies dispatch', () {
    test('nothing installed: the built-in solver by identity', () {
      expect(LayoutStrategies.installed, isNull);
      expect(LayoutStrategies.active, same(const BuiltinLayoutStrategy()));
      final viaDispatcher = LayoutStrategies.solve(chatSpec, columns: 100, rows: 24);
      expect(viaDispatcher.columnTrackSizes, [65, 35]);
    });

    test('an installed strategy replaces the live path', () {
      final focus = _EqualShareStrategy();
      LayoutStrategies.install(focus);
      expect(LayoutStrategies.active, same(focus));
      final solved = LayoutStrategies.solve(chatSpec, columns: 100, rows: 24);
      // Equal shares instead of 65/35.
      expect(solved.columnTrackSizes, [50, 50]);
    });

    test('uninstall returns the default', () {
      LayoutStrategies.install(_EqualShareStrategy());
      LayoutStrategies.uninstall();
      expect(LayoutStrategies.installed, isNull);
      expect(
          LayoutStrategies.solve(chatSpec, columns: 100, rows: 24)
              .columnTrackSizes,
          [65, 35]);
    });

    test('a throwing strategy falls back to the built-in solver + notice',
        () {
      final notices = <String>[];
      LayoutStrategies.onFallbackNotice = notices.add;
      addTearDown(() => LayoutStrategies.onFallbackNotice = null);
      LayoutStrategies.install(_ThrowingStrategy());

      final solved = LayoutStrategies.solve(chatSpec, columns: 100, rows: 24);
      expect(solved.columnTrackSizes, [65, 35],
          reason: 'the screen still solves correctly');
      expect(notices, hasLength(1));
      expect(notices.single, contains('boom-strategy'));
      expect(notices.single, contains('using the built-in solver'));

      // Once per install: repeated failures stay silent, the fallback keeps
      // working.
      final again = LayoutStrategies.solve(chatSpec, columns: 120, rows: 30);
      expect(again.columnTrackSizes, [78, 42]);
      expect(notices, hasLength(1));

      // A fresh install re-arms the notice.
      LayoutStrategies.install(_ThrowingStrategy(id: 'boom-two'));
      LayoutStrategies.solve(chatSpec, columns: 100, rows: 24);
      expect(notices, hasLength(2));
      expect(notices.last, contains('boom-two'));
    });

    test('a strategy whose describe() also throws still falls back', () {
      LayoutStrategies.install(_ThrowingStrategy(describeThrows: true));
      final solved = LayoutStrategies.solve(chatSpec, columns: 100, rows: 24);
      expect(solved.columnTrackSizes, [65, 35]);
    });

    test('the notice callback never throws past the dispatcher', () {
      LayoutStrategies.onFallbackNotice = (_) => throw StateError('bad sink');
      addTearDown(() => LayoutStrategies.onFallbackNotice = null);
      LayoutStrategies.install(_ThrowingStrategy());
      expect(LayoutStrategies.solve(chatSpec, columns: 100, rows: 24)
          .columnTrackSizes, [65, 35]);
    });

    test('a garbage solution record (out-of-terminal rect) falls back', () {
      LayoutStrategies.install(_GarbageRectStrategy());
      final viaDispatcher =
          LayoutStrategies.solve(chatSpec, columns: 40, rows: 10);
      final viaCore =
          GridSolver.solve(chatSpec, columns: 40, rows: 10);
      expect(viaDispatcher.rects, viaCore.rects,
          reason: 'the screen still solves with the core geometry');
    });

    test('a garbage solution record (negative extent) falls back', () {
      LayoutStrategies.install(_NegativeRectStrategy());
      final viaDispatcher =
          LayoutStrategies.solve(chatSpec, columns: 40, rows: 10);
      final viaCore =
          GridSolver.solve(chatSpec, columns: 40, rows: 10);
      expect(viaDispatcher.rects, viaCore.rects);
    });
  });

  group('LayoutWire round-trip', () {
    test('spec and solution survive the boundary records', () {
      final solution = GridSolver.solve(chatSpec, columns: 120, rows: 25);
      final solutionRecord = LayoutWire.solution(solution);
      final back = LayoutWire.solutionFromRecord(solutionRecord);
      expect(back.columns, 120);
      expect(back.rows, 25);
      expect(back.rects, solution.rects);
      expect(back.columnTrackSizes, solution.columnTrackSizes);
      expect(back.rowTrackSizes, solution.rowTrackSizes);
      expect(back.dropped.map((d) => d.id), solution.dropped.map((d) => d.id));
      expect(back.overflowUnitsX, solution.overflowUnitsX);
      expect(back.trailingGapUnitsY, solution.trailingGapUnitsY);
      expect(back.hitTest(70, 5), solution.hitTest(70, 5));

      final specRecord = LayoutWire.spec(chatSpec);
      final specBack = LayoutWire.specFromRecord(specRecord);
      final resolved = GridSolver.solve(specBack, columns: 120, rows: 25);
      expect(resolved.rects, solution.rects);
    });

    test('auto spans, optional bounds and priorities round-trip', () {
      const spec = GridSpec(
        columns: [GridTrack.auto(minUnits: 2), GridTrack.fixed(0.25)],
        rows: [GridTrack.weighted(1), GridTrack.auto(minUnits: 3)],
        items: [
          GridItem(
              id: 'a',
              minWidthUnits: 10,
              maxHeightUnits: 6,
              aspectHint: 1.5,
              priority: 4),
          GridItem(id: 'b', column: TrackSpan.span(2), row: TrackSpan.auto()),
        ],
      );
      final solved = GridSolver.solve(spec, columns: 40, rows: 20);
      final back = LayoutWire.solutionFromRecord(LayoutWire.solution(solved));
      expect(back.rects, solved.rects);
      final specBack = LayoutWire.specFromRecord(LayoutWire.spec(spec));
      expect(GridSolver.solve(specBack, columns: 40, rows: 20).rects,
          solved.rects);
    });

    test('non-standard metrics round-trip', () {
      final metrics = CellMetrics.fromPixels(cellWidthPx: 8, cellHeightPx: 19);
      const spec = GridSpec(
        columns: [GridTrack.fixed(1), GridTrack.weighted(1)],
        rows: [GridTrack.weighted(1)],
        items: [
          GridItem(id: 'body', column: TrackSpan.at(1), row: TrackSpan.at(0))
        ],
      );
      final solved = GridSolver.solve(spec,
          columns: 30, rows: 20, metrics: metrics);
      final back = LayoutWire.solutionFromRecord(LayoutWire.solution(solved));
      expect(back.metrics.rowsPerUnit, closeTo(19 / 8, 1e-12));
      expect(back.rects, solved.rects);
    });

    test('decode rejects records that would change what a rect is', () {
      expect(
          () => LayoutWire.solutionFromRecord({
                'columns': 40,
                'rows': 10,
                'metrics': {'rows-per-unit': 2.0},
                'rects': [
                  {
                    'id': 'x',
                    'rect': {'col': 0, 'row': 0, 'width': 45, 'height': 5},
                  }
                ],
                'column-track-sizes': [40.0],
                'row-track-sizes': [5.0],
                'dropped': [],
                'overflow-units-x': 0.0,
                'overflow-units-y': 0.0,
                'trailing-gap-units-x': 0.0,
                'trailing-gap-units-y': 0.0,
              }),
          throwsFormatException);
      expect(
          () => LayoutWire.solutionFromRecord({
                'columns': 40,
                'rows': 10,
                'metrics': {'rows-per-unit': 2.0},
                'rects': [
                  {
                    'id': 'x',
                    'rect': {'col': 0, 'row': 0, 'width': -3, 'height': 5},
                  }
                ],
                'column-track-sizes': [40.0],
                'row-track-sizes': [5.0],
                'dropped': [],
                'overflow-units-x': 0.0,
                'overflow-units-y': 0.0,
                'trailing-gap-units-x': 0.0,
                'trailing-gap-units-y': 0.0,
              }),
          throwsFormatException);
    });
  });
}

/// The "focus" strategy shape: weighted tracks share equally regardless of
/// their declared weights. Deliberately different from the built-in
/// solver's weighted distribution.
final class _EqualShareStrategy implements LayoutStrategy {
  @override
  String get id => 'tina/layout-focus';

  @override
  StrategyDescriptor describe() => const StrategyDescriptor(
      id: 'test/equal-share',
      version: '1.0.0',
      description: 'Weighted tracks split the remainder evenly.');

  @override
  GridSolution solveSpec(GridSpec spec,
      {required int columns,
      required int rows,
      CellMetrics metrics = CellMetrics.standard}) {
    final flattened = GridSpec(
      columns: [
        for (final t in spec.columns)
          t.kind == TrackKind.weighted
              ? const GridTrack.weighted(1,
                  minUnits: 0, maxUnits: double.infinity)
              : t,
      ],
      rows: [
        for (final t in spec.rows)
          t.kind == TrackKind.weighted
              ? const GridTrack.weighted(1,
                  minUnits: 0, maxUnits: double.infinity)
              : t,
      ],
      items: spec.items,
    );
    // The wire round-trip is part of the strategy contract.
    final solved = GridSolver.solve(LayoutWire.specFromRecord(
        LayoutWire.spec(flattened)), columns: columns, rows: rows, metrics: metrics);
    return LayoutWire.solutionFromRecord(LayoutWire.solution(solved));
  }
}

final class _ThrowingStrategy implements LayoutStrategy {
  _ThrowingStrategy({this.id = 'boom-strategy', this.describeThrows = false});

  final String id;
  final bool describeThrows;

  @override
  StrategyDescriptor describe() {
    if (describeThrows) throw StateError('describe failed');
    return StrategyDescriptor(id: id, version: '1.0.0', description: id);
  }

  @override
  GridSolution solveSpec(GridSpec spec,
      {required int columns,
      required int rows,
      CellMetrics metrics = CellMetrics.standard}) {
    throw StateError('strategy blew up');
  }
}

final class _GarbageRectStrategy implements LayoutStrategy {
  @override
  String get id => 'bad/garbage';

  @override
  StrategyDescriptor describe() => const StrategyDescriptor(
      id: 'test/garbage-rect', version: '1.0.0', description: 'garbage');

  @override
  GridSolution solveSpec(GridSpec spec,
      {required int columns,
      required int rows,
      CellMetrics metrics = CellMetrics.standard}) {
    final solved = GridSolver.solve(spec,
        columns: columns, rows: rows, metrics: metrics);
    final record = LayoutWire.solution(solved);
    (record['rects'] as List).first['rect']['width'] = columns + 100;
    return LayoutWire.solutionFromRecord(record); // throws -> fallback
  }
}

final class _NegativeRectStrategy implements LayoutStrategy {
  @override
  String get id => 'bad/negative';

  @override
  StrategyDescriptor describe() => const StrategyDescriptor(
      id: 'test/negative-rect', version: '1.0.0', description: 'garbage');

  @override
  GridSolution solveSpec(GridSpec spec,
      {required int columns,
      required int rows,
      CellMetrics metrics = CellMetrics.standard}) {
    final solved = GridSolver.solve(spec,
        columns: columns, rows: rows, metrics: metrics);
    final record = LayoutWire.solution(solved);
    (record['rects'] as List).first['rect']['height'] = -5;
    return LayoutWire.solutionFromRecord(record); // throws -> fallback
  }
}
