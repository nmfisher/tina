import 'geometry.dart';

/// One item to place: an identified region of the grid.
///
/// Sizes are in square units; `0.5` vertical units is one screen row under
/// the standard 2:1 cell metric.
final class GridItem {
  final String id;

  /// Column placement. Explicit tracks or auto-flow (see [TrackSpan]).
  final TrackSpan column;

  /// Row placement. Explicit tracks or auto-flow.
  final TrackSpan row;

  /// Content minimum width in units. Feeds `auto` column tracks.
  final double minWidthUnits;

  /// Content minimum height in units. Feeds `auto` row tracks.
  final double minHeightUnits;

  /// Content maximum width in units, if bounded.
  final double? maxWidthUnits;

  /// Content maximum height in units, if bounded.
  final double? maxHeightUnits;

  /// Width/height ratio in square units. When the item sits in an `auto`
  /// row track, the solver sizes that track from the item's solved column
  /// width (`height = width / aspectHint`) clamped to the item and track
  /// bounds — so images and other fixed-aspect content get proportioned
  /// boxes. Use [CellMetrics.aspectFromPixels] to build one from pixels.
  final double? aspectHint;

  /// Retention priority under overflow. Higher wins; among equals the item
  /// declared LATER is dropped first (newest goes first when space runs
  /// out). Items are only dropped when minimums cannot fit — see
  /// [GridSolution.dropped].
  final int priority;

  const GridItem({
    required this.id,
    this.column = const TrackSpan.auto(),
    this.row = const TrackSpan.auto(),
    this.minWidthUnits = 0,
    this.minHeightUnits = 0,
    this.maxWidthUnits,
    this.maxHeightUnits,
    this.aspectHint,
    this.priority = 0,
  });
}

/// Declarative grid template: tracks plus the items placed into them.
///
/// A [GridSpec] plus a terminal size is a pure function to a
/// [GridSolution] (see [GridSolver.solve]) — no I/O, no clock, fully
/// testable, renderer-agnostic.
final class GridSpec {
  final List<GridTrack> columns;
  final List<GridTrack> rows;
  final List<GridItem> items;

  const GridSpec(
      {required this.columns, required this.rows, required this.items});
}

/// An item removed by the solver, with the reason it could not be kept.
final class GridDrop {
  final String id;
  final String reason;

  const GridDrop({required this.id, required this.reason});

  @override
  String toString() => 'GridDrop($id: $reason)';
}
