import 'package:tina_console/tina_console.dart';
import 'package:tina_layout/tina_layout.dart';
import 'package:test/test.dart';

/// The screen-level swap proof: installing a strategy plugin visibly
/// changes the chat screen's arrangement; uninstalling returns the
/// default byte-for-byte; a failing strategy leaves the screen correct.
/// (The strategies here are Dart stand-ins for the wasm components —
/// the dispatcher contract they exercise is identical, and the wasm
/// parity is pinned by tina_layout_plugins + the Rust host tests.)
void main() {
  tearDown(() {
    LayoutStrategies.uninstall();
    LayoutStrategies.onFallbackNotice = null;
  });

  test('default: the compiled-in solver is the live path', () {
    final layout = ScreenLayout.fromSize(120, 30);
    expect(LayoutStrategies.installed, isNull);
    expect(layout.chatRightCol, 77); // 65% of 120
    expect(layout.infoLeftCol, 78);
  });

  test('installing the focus strategy visibly changes the screen', () {
    final before = ScreenLayout.fromSize(120, 30);
    LayoutStrategies.install(_EqualShareStrategy());
    final after = ScreenLayout.fromSize(120, 30);
    expect(after.chatRightCol, 59, reason: '65/35 becomes 50/50');
    expect(after.infoLeftCol, 60);
    expect(after.chat.width, lessThan(before.chat.width),
        reason: 'the chat pane visibly narrows');
    expect(after.info.width, greaterThan(before.info.width));
    // The stack (strip, input, borders) is untouched by the strategy.
    expect(after.stripRow, before.stripRow);
    expect(after.inputRow, before.inputRow);
    expect(after.topBorderRow, before.topBorderRow);
  });

  test('uninstalling restores the default byte-for-byte', () {
    final defaultGeometry = ScreenLayout.fromSize(120, 30);
    LayoutStrategies.install(_EqualShareStrategy());
    final focused = ScreenLayout.fromSize(120, 30);
    expect(focused.chatRightCol, isNot(defaultGeometry.chatRightCol),
        reason: 'the strategy really changed the screen first');
    LayoutStrategies.uninstall();
    final restored = ScreenLayout.fromSize(120, 30);
    // Rect has no ==; compare the geometry field-by-field.
    expect(
        (restored.chat.row, restored.chat.col, restored.chat.width,
            restored.chat.height),
        (defaultGeometry.chat.row, defaultGeometry.chat.col,
            defaultGeometry.chat.width, defaultGeometry.chat.height));
    expect(
        (restored.info.row, restored.info.col, restored.info.width,
            restored.info.height),
        (defaultGeometry.info.row, defaultGeometry.info.col,
            defaultGeometry.info.width, defaultGeometry.info.height));
    expect(
        (restored.input.row, restored.input.col, restored.input.width),
        (defaultGeometry.input.row, defaultGeometry.input.col,
            defaultGeometry.input.width));
    expect(
        (restored.sidebar.row, restored.sidebar.col, restored.sidebar.width,
            restored.sidebar.height),
        (defaultGeometry.sidebar.row, defaultGeometry.sidebar.col,
            defaultGeometry.sidebar.width, defaultGeometry.sidebar.height));
    expect(restored.chatRightCol, defaultGeometry.chatRightCol);
    expect(restored.stripRow, defaultGeometry.stripRow);
  });

  test('a throwing strategy leaves the screen correct (fallback + notice)',
      () {
    final notices = <String>[];
    LayoutStrategies.onFallbackNotice = notices.add;
    LayoutStrategies.install(_ThrowingStrategy());
    final layout = ScreenLayout.fromSize(120, 30);
    // The screen is still the default geometry.
    expect(layout.chatRightCol, 77);
    expect(layout.infoLeftCol, 78);
    expect(layout.chat.col, 1);
    expect(layout.stripRow, 29);
    expect(notices, hasLength(1));
    expect(notices.single, contains('using the built-in solver'));
  });
}

final class _EqualShareStrategy implements LayoutStrategy {
  @override
  StrategyDescriptor describe() => const StrategyDescriptor(
      id: 'tina/layout-focus',
      version: '1.0.0',
      description: 'equal-share weighted tracks');

  @override
  GridSolution solveSpec(GridSpec spec,
      {required int columns,
      required int rows,
      CellMetrics metrics = CellMetrics.standard}) {
    final focused = GridSpec(
      columns: [
        for (final t in spec.columns)
          t.kind == TrackKind.weighted
              ? GridTrack.weighted(1,
                  minUnits: t.minUnits,
                  maxUnits: t.maxUnits.isInfinite ? null : t.maxUnits)
              : t,
      ],
      rows: [
        for (final t in spec.rows)
          t.kind == TrackKind.weighted
              ? GridTrack.weighted(1,
                  minUnits: t.minUnits,
                  maxUnits: t.maxUnits.isInfinite ? null : t.maxUnits)
              : t,
      ],
      items: spec.items,
    );
    return GridSolver.solve(focused,
        columns: columns, rows: rows, metrics: metrics);
  }
}

final class _ThrowingStrategy implements LayoutStrategy {
  @override
  StrategyDescriptor describe() => const StrategyDescriptor(
      id: 'bad/layout', version: '1.0.0', description: 'throws');

  @override
  GridSolution solveSpec(GridSpec spec,
      {required int columns,
      required int rows,
      CellMetrics metrics = CellMetrics.standard}) {
    throw StateError('strategy blew up');
  }
}
