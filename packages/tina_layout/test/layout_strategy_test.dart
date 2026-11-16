import 'package:test/test.dart';
import 'package:tina_layout/tina_layout.dart';

void main() {
  GridSpec twoColumnSpec({double left = 65, double right = 35}) => GridSpec(
      columns: [
        GridTrack.weighted(left, minUnits: 30),
        GridTrack.weighted(right, minUnits: 20),
      ],
      rows: const [GridTrack.weighted(1)],
      items: const [
        GridItem(
            id: 'chat', column: TrackSpan.at(0), row: TrackSpan.at(0)),
        GridItem(
            id: 'info', column: TrackSpan.at(1), row: TrackSpan.at(0)),
      ]);

  tearDown(() => LayoutStrategies.uninstall());

  group('BuiltinLayoutStrategy', () {
    test('solves identically to the grid solver', () {
      final spec = twoColumnSpec();
      final viaStrategy = const BuiltinLayoutStrategy()
          .solveSpec(spec, columns: 120, rows: 30);
      final direct =
          GridSolver.solve(spec, columns: 120, rows: 30);
      expect(viaStrategy.rectOf('chat'), direct.rectOf('chat'));
      expect(viaStrategy.rectOf('info'), direct.rectOf('info'));
    });

    test('carries the default descriptor', () {
      const strategy = BuiltinLayoutStrategy();
      expect(strategy.id, 'default');
      expect(strategy.describe().version, isNotEmpty);
      expect(strategy.id, 'default');
    });
  });

  group('FocusLayoutStrategy', () {
    test('weighted tracks share equally: 65/35 becomes 50/50', () {
      final solution = const FocusLayoutStrategy()
          .solveSpec(twoColumnSpec(), columns: 120, rows: 30);
      expect(solution.rectOf('chat')!.width, 60);
      expect(solution.rectOf('info')!.width, 60);
    });

    test('a single weighted track still takes everything', () {
      final spec = GridSpec(
          columns: const [
            GridTrack.fixed(1),
            GridTrack.weighted(65),
            GridTrack.fixed(1),
          ],
          rows: const [GridTrack.weighted(1)],
          items: const [
            GridItem(
                id: 'body',
                column: TrackSpan.at(1),
                row: TrackSpan.at(0)),
          ]);
      final solution =
          const FocusLayoutStrategy().solveSpec(spec, columns: 80, rows: 20);
      expect(solution.rectOf('body')!.width, 78);
    });

    test('minimums survive equal sharing', () {
      final solution = const FocusLayoutStrategy().solveSpec(
          twoColumnSpec(left: 90, right: 10),
          columns: 55,
          rows: 30);
      // 55 columns shared equally would starve the info track below its
      // floor of 20; the solver keeps the floor instead.
      expect(solution.rectOf('info')!.width, greaterThanOrEqualTo(20));
    });
  });

  group('LayoutStrategies dispatcher', () {
    test('with nothing installed it is the built-in solver', () {
      final spec = twoColumnSpec();
      expect(LayoutStrategies.hasCustom, isFalse);
      expect(LayoutStrategies.installed, isNull);
      final viaDispatcher =
          LayoutStrategies.solve(spec, columns: 100, rows: 24);
      final direct = GridSolver.solve(spec, columns: 100, rows: 24);
      expect(viaDispatcher.rectOf('chat'), direct.rectOf('chat'));
      expect(viaDispatcher.rectOf('info'), direct.rectOf('info'));
    });

    test('install and uninstall switch the active strategy', () {
      const focus = FocusLayoutStrategy();
      LayoutStrategies.install(focus);
      expect(LayoutStrategies.active, same(focus));
      expect(LayoutStrategies.hasCustom, isTrue);
      final spec = twoColumnSpec();
      expect(
          LayoutStrategies
              .solve(spec, columns: 120, rows: 30)
              .rectOf('chat')!
              .width,
          60);
      LayoutStrategies.uninstall();
      expect(LayoutStrategies.active.id, 'default');
      expect(
          LayoutStrategies
              .solve(spec, columns: 120, rows: 30)
              .rectOf('chat')!
              .width,
          78);
    });

    test('a throwing strategy falls back to the built-in, noticed once',
        () {
      final notices = <String>[];
      LayoutStrategies.onFallbackNotice = notices.add;
      addTearDown(() => LayoutStrategies.onFallbackNotice = null);
      LayoutStrategies.install(_ThrowingStrategy());
      final spec = twoColumnSpec();
      final solution =
          LayoutStrategies.solve(spec, columns: 120, rows: 30);
      // The built-in solver's geometry, not a crash.
      expect(solution.rectOf('chat')!.width, 78);
      LayoutStrategies.solve(spec, columns: 100, rows: 24);
      LayoutStrategies.solve(spec, columns: 80, rows: 20);
      expect(notices, hasLength(1));
      expect(notices.single, contains('boom'));
      expect(notices.single, contains('built-in'));
      // A reinstall re-arms the notice.
      LayoutStrategies.install(_ThrowingStrategy());
      LayoutStrategies.solve(spec, columns: 120, rows: 30);
      expect(notices, hasLength(2));
    });

    test('listeners hear installs and uninstalls', () {
      var changes = 0;
      void listener() => changes++;
      LayoutStrategies.addListener(listener);
      addTearDown(() => LayoutStrategies.removeListener(listener));
      LayoutStrategies.install(const FocusLayoutStrategy());
      LayoutStrategies.uninstall();
      LayoutStrategies.uninstall(); // idempotent, no event
      expect(changes, 2);
    });
  });
}

final class _ThrowingStrategy implements LayoutStrategy {
  @override
  String get id => 'throwing/test';

  @override
  StrategyDescriptor describe() => const StrategyDescriptor(
      id: 'throwing/test', version: '1.0.0', description: 'throws');

  @override
  GridSolution solveSpec(GridSpec spec,
      {required int columns,
      required int rows,
      CellMetrics metrics = CellMetrics.standard}) {
    throw StateError('boom');
  }
}
