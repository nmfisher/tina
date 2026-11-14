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

  tearDown(() => LayoutStrategies.instance.uninstall());

  group('BuiltinLayoutStrategy', () {
    test('solves identically to the grid solver', () {
      final spec = twoColumnSpec();
      final viaStrategy = const BuiltinLayoutStrategy()
          .solve(spec, columns: 120, rows: 30);
      final direct =
          GridSolver.solve(spec, columns: 120, rows: 30);
      expect(viaStrategy.rectOf('chat'), direct.rectOf('chat'));
      expect(viaStrategy.rectOf('info'), direct.rectOf('info'));
    });

    test('carries the default descriptor', () {
      const strategy = BuiltinLayoutStrategy();
      expect(strategy.id, 'default');
      expect(strategy.version, isNotEmpty);
    });
  });

  group('FocusLayoutStrategy', () {
    test('weighted tracks share equally: 65/35 becomes 50/50', () {
      final solution = const FocusLayoutStrategy()
          .solve(twoColumnSpec(), columns: 120, rows: 30);
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
          const FocusLayoutStrategy().solve(spec, columns: 80, rows: 20);
      expect(solution.rectOf('body')!.width, 78);
    });

    test('minimums survive equal sharing', () {
      final solution = const FocusLayoutStrategy().solve(
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
      expect(LayoutStrategies.instance.hasCustom, isFalse);
      final viaDispatcher =
          LayoutStrategies.instance.solve(spec, columns: 100, rows: 24);
      final direct = GridSolver.solve(spec, columns: 100, rows: 24);
      expect(viaDispatcher.rectOf('chat'), direct.rectOf('chat'));
      expect(viaDispatcher.rectOf('info'), direct.rectOf('info'));
    });

    test('install and uninstall switch the active strategy', () {
      const focus = FocusLayoutStrategy();
      LayoutStrategies.instance.install(focus);
      expect(LayoutStrategies.instance.active, same(focus));
      expect(LayoutStrategies.instance.hasCustom, isTrue);
      final spec = twoColumnSpec();
      expect(
          LayoutStrategies.instance
              .solve(spec, columns: 120, rows: 30)
              .rectOf('chat')!
              .width,
          60);
      LayoutStrategies.instance.uninstall();
      expect(LayoutStrategies.instance.active.id, 'default');
      expect(
          LayoutStrategies.instance
              .solve(spec, columns: 120, rows: 30)
              .rectOf('chat')!
              .width,
          78);
    });

    test('a throwing strategy falls back to the built-in, noticed once',
        () {
      final notices = <String>[];
      LayoutStrategies.instance.onFallbackNotice = notices.add;
      addTearDown(() => LayoutStrategies.instance.onFallbackNotice = null);
      LayoutStrategies.instance.install(_ThrowingStrategy());
      final spec = twoColumnSpec();
      final solution =
          LayoutStrategies.instance.solve(spec, columns: 120, rows: 30);
      // The built-in solver's geometry, not a crash.
      expect(solution.rectOf('chat')!.width, 78);
      LayoutStrategies.instance.solve(spec, columns: 100, rows: 24);
      LayoutStrategies.instance.solve(spec, columns: 80, rows: 20);
      expect(notices, hasLength(1));
      expect(notices.single, contains('boom'));
      expect(notices.single, contains('built-in'));
      // A reinstall re-arms the notice.
      LayoutStrategies.instance.install(_ThrowingStrategy());
      LayoutStrategies.instance.solve(spec, columns: 120, rows: 30);
      expect(notices, hasLength(2));
    });

    test('listeners hear installs and uninstalls', () {
      var changes = 0;
      void listener() => changes++;
      LayoutStrategies.instance.addListener(listener);
      addTearDown(() => LayoutStrategies.instance.removeListener(listener));
      LayoutStrategies.instance.install(const FocusLayoutStrategy());
      LayoutStrategies.instance.uninstall();
      LayoutStrategies.instance.uninstall(); // idempotent, no event
      expect(changes, 2);
    });
  });
}

final class _ThrowingStrategy implements LayoutStrategy {
  @override
  String get id => 'throwing/test';

  @override
  String get version => '1.0.0';

  @override
  GridSolution solve(GridSpec spec,
      {required int columns, required int rows}) {
    throw StateError('boom');
  }
}
