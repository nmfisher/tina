import 'package:tina_layout/tina_layout.dart';
import 'package:test/test.dart';

/// Timing evidence for the report: a resize burst through the dispatcher
/// with (a) the built-in solver and (b) the wire round trip the plugin
/// performs, over the chat screen's actual outer + interior grids — the
/// same two solves a real resize triggers.
void main() {
  const columns = 120;
  const rows = 30;
  const burst = 200;

  test('resize burst: builtin vs plugin-path solve timing', () {
    final sw = Stopwatch()..start();
    for (var i = 0; i < burst; i++) {
      GridSolver.solve(_outer(), columns: columns - (i % 7), rows: rows);
      GridSolver.solve(_interior(),
          columns: 77 - (i % 5), rows: 23, metrics: CellMetrics.standard);
    }
    sw.stop();
    final builtinUs = sw.elapsedMicroseconds / burst;

    sw.reset();
    sw.start();
    for (var i = 0; i < burst; i++) {
      LayoutWire.solutionFromRecord(LayoutWire.solution(GridSolver.solve(
          LayoutWire.specFromRecord(
              LayoutWire.spec(_outer())),
          columns: columns - (i % 7),
          rows: rows)));
      LayoutWire.solutionFromRecord(LayoutWire.solution(GridSolver.solve(
          LayoutWire.specFromRecord(LayoutWire.spec(_interior())),
          columns: 77 - (i % 5),
          rows: 23)));
    }
    sw.stop();
    final pluginPathUs = sw.elapsedMicroseconds / burst;

    // Recorded in the report; the assertion only guards against a
    // pathological regression (the boundary records must stay cheap
    // relative to a frame budget).
    print('builtin: ${builtinUs.toStringAsFixed(1)} us/solve-pair');
    print('plugin-path (wire round trip): '
        '${pluginPathUs.toStringAsFixed(1)} us/solve-pair');
    print('ratio: ${(pluginPathUs / builtinUs).toStringAsFixed(2)}x');
    expect(pluginPathUs, lessThan(2000),
        reason: 'a solve pair must stay far below a frame budget');
  });
}

GridSpec _outer() => const GridSpec(
      columns: [
        GridTrack.weighted(65, minUnits: 30),
        GridTrack.weighted(35, minUnits: 20),
      ],
      rows: [
        GridTrack.fixed(0.5),
        GridTrack.weighted(1),
        GridTrack.fixed(0.5),
      ],
      items: [
        GridItem(
            id: 'chatBox',
            column: TrackSpan.at(0),
            row: TrackSpan.at(1)),
        GridItem(
            id: 'infoBox', column: TrackSpan.at(1), row: TrackSpan.at(1)),
      ],
    );

GridSpec _interior() => const GridSpec(
      columns: [
        GridTrack.fixed(1),
        GridTrack.weighted(1),
        GridTrack.fixed(1),
      ],
      rows: [
        GridTrack.fixed(0.5),
        GridTrack.weighted(1),
        GridTrack.fixed(0.5),
        GridTrack.fixed(0.5),
      ],
      items: [
        GridItem(
            id: 'content', column: TrackSpan.at(1), row: TrackSpan.at(1)),
        GridItem(id: 'input', column: TrackSpan.at(1), row: TrackSpan.at(2)),
      ],
    );
