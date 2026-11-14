/// Pixel geometry of terminal cells, expressed as a single number: how many
/// screen ROWS one square layout unit spans vertically.
///
/// The layout unit is a SQUARE screen patch. Horizontally one unit is always
/// exactly one cell column. Vertically a unit spans [rowsPerUnit] rows. With
/// the standard terminal cell aspect (cells twice as tall as they are wide)
/// one unit is `1 column x 2 rows` — the default here, and the geometry every
/// track size in tina's specs is written against (half a unit = one row).
///
/// Real terminals report cell pixel metrics; pass them to
/// [CellMetrics.fromPixels] and all aspect math stays square-correct without
/// changing any spec.
final class CellMetrics {
  /// Standard ~2:1 cell aspect: one unit = 1 column x 2 rows.
  static const CellMetrics standard = CellMetrics._(2.0);

  /// Rows spanned vertically by one square unit. Always > 0.
  final double rowsPerUnit;

  const CellMetrics._(this.rowsPerUnit);

  /// Metrics from real cell pixel dimensions. Both must be positive.
  factory CellMetrics.fromPixels(
      {required int cellWidthPx, required int cellHeightPx}) {
    if (cellWidthPx <= 0 || cellHeightPx <= 0) {
      throw ArgumentError.value(
          '$cellWidthPx x $cellHeightPx', 'cell', 'cell pixels must be > 0');
    }
    return CellMetrics._(cellHeightPx / cellWidthPx);
  }

  /// Convert a vertical extent in units to rows (may be fractional).
  double unitsToRows(double units) => units * rowsPerUnit;

  /// Convert a row extent to units (may be fractional).
  double rowsToUnits(double rows) => rows / rowsPerUnit;

  /// An item `widthPx / heightPx` pixels wide/tall expressed as a
  /// width/height ratio in square units (what [GridItem.aspectHint] wants).
  ///
  /// A square-in-pixels image maps to a ratio that renders square on screen:
  /// `aspectFromPixels(100, 100)` is `4` under the standard 2:1 metric
  /// because a visually square patch is 4 columns x 2 rows = 4 x 1 units.
  double aspectFromPixels(num widthPx, num heightPx) =>
      (widthPx / heightPx) * rowsPerUnit * rowsPerUnit;

  /// Snap a horizontal unit edge to a cell column.
  int snapColumn(double unitEdge) => unitEdge.round();

  /// Snap a vertical unit edge to a cell row.
  int snapRow(double unitEdge) => (unitEdge * rowsPerUnit).round();

  @override
  bool operator ==(Object other) =>
      other is CellMetrics && other.rowsPerUnit == rowsPerUnit;

  @override
  int get hashCode => rowsPerUnit.hashCode;

  @override
  String toString() => 'CellMetrics(rowsPerUnit: $rowsPerUnit)';
}

/// Horizontal/vertical placement of an item along one axis of the template.
///
/// * [TrackSpan.at] — explicit track index (0-based), optionally spanning.
/// * [TrackSpan.span] — span N tracks, auto-placed by the solver.
/// * [TrackSpan.auto] — span 1, auto-placed.
///
/// Spans and starts are clamped into the template; an item can never end up
/// outside it.
final class TrackSpan {
  /// Track index, or `null` for solver auto-placement.
  final int? start;

  /// Number of tracks covered, >= 1.
  final int span;

  const TrackSpan._(this.start, this.span);

  /// Place at [index] (0-based) covering [span] tracks.
  const TrackSpan.at(int index, {int span = 1}) : this._(index, span);

  /// Auto-place covering [count] tracks.
  const TrackSpan.span(int count) : this._(null, count);

  /// Auto-place in a single track.
  const TrackSpan.auto() : this._(null, 1);
}

/// One track (row or column) of a [GridSpec] template.
///
/// Sizes are in square units (see [CellMetrics]); with the standard 2:1
/// metric a `fixed(0.5)` vertical track is exactly one screen row.
///
/// * fixed — a constant size.
/// * weighted — shares the space left by fixed/auto tracks by [weight]
///   (largest-remainder rounding, ties to the earlier track).
/// * auto — sized from the content minimums of items placed in it.
///
/// Every kind honors [minUnits]/[maxUnits]; minimums are hard floors: the
/// solver shrinks elsewhere (and finally drops low-priority items) rather
/// than emit rects below them, and never emits a rect larger than a max.
final class GridTrack {
  final TrackKind kind;

  /// Size for [TrackKind.fixed] tracks, in units.
  final double sizeUnits;

  /// Weight for [TrackKind.weighted] tracks. <= 0 contributes no share.
  final double weight;

  /// Hard floor in units.
  final double minUnits;

  /// Hard ceiling in units.
  final double maxUnits;

  const GridTrack._(this.kind, this.sizeUnits, this.weight, this.minUnits,
      this.maxUnits);

  const GridTrack.fixed(double units, {double minUnits = 0, double? maxUnits})
      : this._(TrackKind.fixed, units, 0, minUnits,
            maxUnits ?? double.infinity);

  const GridTrack.weighted(double weight,
      {double minUnits = 0, double? maxUnits})
      : this._(TrackKind.weighted, 0, weight, minUnits,
            maxUnits ?? double.infinity);

  const GridTrack.auto({double minUnits = 0, double? maxUnits})
      : this._(TrackKind.auto, 0, 0, minUnits, maxUnits ?? double.infinity);
}

enum TrackKind { fixed, weighted, auto }

/// A rectangle in terminal CELLS (what renderers consume).
final class GridRect {
  final int col;
  final int row;
  final int width;
  final int height;

  const GridRect(
      {required this.col,
      required this.row,
      required this.width,
      required this.height});

  static const empty = GridRect(col: 0, row: 0, width: 0, height: 0);

  bool get isEmpty => width <= 0 || height <= 0;

  bool contains(int cellCol, int cellRow) =>
      cellCol >= col &&
      cellCol < col + width &&
      cellRow >= row &&
      cellRow < row + height;

  @override
  bool operator ==(Object other) =>
      other is GridRect &&
      other.col == col &&
      other.row == row &&
      other.width == width &&
      other.height == height;

  @override
  int get hashCode => Object.hash(col, row, width, height);

  @override
  String toString() =>
      'GridRect(col: $col, row: $row, w: $width, h: $height)';
}
