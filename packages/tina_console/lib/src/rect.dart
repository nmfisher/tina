/// Absolute terminal rectangle. Coordinates are 0-indexed.
///
/// `row` and `col` are the top-left cell. `width` and `height` are the
/// extent in cells. Empty rectangles (`width == 0` or `height == 0`) are
/// legal and represent "no space" (used for the status panel in non-split
/// layouts so callers don't need null branches).
class Rect {
  final int row;
  final int col;
  final int width;
  final int height;

  const Rect({
    required this.row,
    required this.col,
    required this.width,
    required this.height,
  });

  static const empty = Rect(row: 0, col: 0, width: 0, height: 0);

  bool get isEmpty => width == 0 || height == 0;

  int get right => col + width - 1;
  int get bottom => row + height - 1;

  bool containsCell(int r, int c) =>
      r >= row && r < row + height && c >= col && c < col + width;

  @override
  String toString() => 'Rect(row:$row col:$col w:$width h:$height)';
}
