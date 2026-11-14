/// Declarative square-grid auto-layout for tina's terminal UIs.
///
/// Pure Dart: no renderer, no I/O, no notcurses. The same [GridSpec] can be
/// solved for a native notcurses plane tree or a wasm virtual cell buffer —
/// layout lives above the renderer split.
///
/// ```dart
/// final solution = GridSolver.solve(
///   GridSpec(
///     columns: [
///       GridTrack.weighted(65, minUnits: 30),
///       GridTrack.weighted(35, minUnits: 20),
///     ],
///     rows: [
///       GridTrack.fixed(0.5), // one screen row at 2:1
///       GridTrack.weighted(1),
///       GridTrack.fixed(0.5),
///     ],
///     items: [
///       GridItem(id: 'transcript', column: const TrackSpan.at(0), row: const TrackSpan.at(1)),
///     ],
///   ),
///   columns: 100,
///   rows: 24,
/// );
/// final rect = solution.rectOf('transcript')!; // in CELLS
/// ```
library;

export 'src/geometry.dart';
export 'src/solver.dart';
export 'src/spec.dart';
