import 'package:tina_layout/tina_layout.dart';

import 'layout_codec.dart';

/// Solve from an already-received boundary map (the guest entry point):
/// map → spec → solve → WIT-shaped record → map → validated solution.
GridSolution solveThroughWireMap(Map<Object?, Object?> received,
    {required int columns,
    required int rows,
    CellMetrics metrics = CellMetrics.standard}) {
  final solved = GridSolver.solve(LayoutWire.specFromRecord(received),
      columns: columns, rows: rows, metrics: metrics);
  return solutionRecordToCore(solutionToRecord(solved));
}

/// Solves through the full boundary round trip: spec → wire map → WIT
/// record → wire map → spec → solve → WIT record → wire map → solution.
/// This is byte-for-byte the path a layout solve takes across the Store
/// boundary, so the differential goldens and the plugin guests exercise
/// one serialization.
GridSolution solveThroughWire(GridSpec spec,
    {required int columns,
    required int rows,
    CellMetrics metrics = CellMetrics.standard}) {
  final received = specMapToRecord(LayoutWire.spec(spec));
  final parsed = specRecordToMap(received);
  return solveThroughWireMap(parsed,
      columns: columns, rows: rows, metrics: metrics);
}

/// Solve a received boundary map under the focus policy (equal-share
/// weighted tracks). The guest entry point for `tina/layout-focus`.
GridSolution focusSolveMap(Map<Object?, Object?> received,
    {required int columns,
    required int rows,
    CellMetrics metrics = CellMetrics.standard}) {
  return const FocusLayoutStrategy().solveSpec(
      LayoutWire.specFromRecord(received),
      columns: columns,
      rows: rows,
      metrics: metrics);
}

/// The built-in solver as a plugin strategy (`tina/layout-solver`): the
/// same code the TUI falls back to, speaking the wire contract.
final class SolverLayoutStrategy implements LayoutStrategy {
  const SolverLayoutStrategy();

  @override
  StrategyDescriptor describe() => const StrategyDescriptor(
        id: 'tina/layout-solver',
        version: '1.0.0',
        description: 'The tina_layout grid solver as an installable '
            'strategy: identical rects to the built-in, by construction.',
      );

  @override
  GridSolution solveSpec(GridSpec spec,
          {required int columns,
          required int rows,
          CellMetrics metrics = CellMetrics.standard}) =>
      solveThroughWire(spec, columns: columns, rows: rows, metrics: metrics);
}

/// The deliberately different demo strategy (`tina/layout-focus`):
/// weighted tracks share the remaining space EQUALLY, ignoring their
/// declared weights. On the chat screen the split goes 65/35 → 50/50 on
/// wide terminals - visibly different, still honoring every minimum.
final class FocusLayoutStrategy implements LayoutStrategy {
  const FocusLayoutStrategy();

  @override
  StrategyDescriptor describe() => const StrategyDescriptor(
        id: 'tina/layout-focus',
        version: '1.0.0',
        description: 'Focus mode: weighted tracks split the remaining '
            'space equally (65/35 becomes 50/50).',
      );

  @override
  GridSolution solveSpec(GridSpec spec,
      {required int columns,
      required int rows,
      CellMetrics metrics = CellMetrics.standard}) {
    final focused = GridSpec(
      columns: [
        for (final t in spec.columns)
          t.kind == TrackKind.weighted
              ? GridTrack.weighted(1, minUnits: t.minUnits,
                  maxUnits: t.maxUnits.isInfinite ? null : t.maxUnits)
              : t,
      ],
      rows: [
        for (final t in spec.rows)
          t.kind == TrackKind.weighted
              ? GridTrack.weighted(1, minUnits: t.minUnits,
                  maxUnits: t.maxUnits.isInfinite ? null : t.maxUnits)
              : t,
      ],
      items: spec.items,
    );
    return solveThroughWire(focused, columns: columns, rows: rows, metrics: metrics);
  }
}

/// The wedge fixture (`tina/layout-hang`): `solve` never returns. Used to
/// prove the host's epoch deadline kills a stuck strategy and the TUI
/// falls back to the built-in solver without wedging the screen. Never
/// install for real use; describe() says so loudly.
final class HangLayoutStrategy implements LayoutStrategy {
  const HangLayoutStrategy();

  @override
  StrategyDescriptor describe() => const StrategyDescriptor(
        id: 'tina/layout-hang',
        version: '1.0.0',
        description: 'TEST FIXTURE: solve() never returns; the host must '
            'epoch-kill it and the TUI must fall back.',
      );

  @override
  GridSolution solveSpec(GridSpec spec,
      {required int columns,
      required int rows,
      CellMetrics metrics = CellMetrics.standard}) {
    var sink = 0;
    while (true) {
      sink = (sink + 1) & 0x3fffffff;
    }
  }
}
