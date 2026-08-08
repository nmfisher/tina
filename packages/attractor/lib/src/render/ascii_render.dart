import 'dart:math' as math;

import '../graph.dart';
import '../run_status.dart';
import 'layout.dart';

/// The rendered graph: a character canvas plus each node's center cell (for
/// selection navigation) and the loop-band lines (back-edges drawn beneath the
/// main graph so they never tangle forward flow).
class RenderResult {
  final List<String> lines;
  final Map<String, NodeCenter> centers;

  RenderResult(this.lines, this.centers);
}

class NodeCenter {
  final int row, col;
  const NodeCenter(this.row, this.col);
}

const _boxMinW = 8;
const _boxMaxW = 24;
const _boxH = 4; // top border, label, sub-line (role/shape), bottom border
const _colGap = 5; // gutter between columns for edge routing
const _rowGap = 2; // vertical gap between stacked nodes

/// Render [g] (already laid out) as ASCII. [selectedId] marks that node's box
/// with a double-line border; [status] switches a node's border glyphs to its
/// live-run state (heavy = running, rounded = done, double = failed — which
/// collides with the selection glyphs; [selectedId] wins when both are given,
/// and the two never co-occur in practice). Direction comes from
/// [layout.direction]; LR is the primary, fully-supported path (TB is rendered
/// as LR for now — a rotated TB path is a follow-up).
RenderResult renderGraph(Graph g,
    {NodeLayout? layout,
    String? selectedId,
    Map<String, NodeRunStatus>? status}) {
  final lo = layout ?? computeLayout(g);
  final cols = lo.ranks;

  // Per-column box widths.
  final colW = List<int>.filled(cols.length, _boxMinW);
  for (var c = 0; c < cols.length; c++) {
    var w = _boxMinW;
    for (final id in cols[c]) {
      final n = g.node(id)!;
      var innerNeeded = _displayWidth(n.label) + 2;
      final sub = _subLine(n);
      if (sub != null) innerNeeded = math.max(innerNeeded, _displayWidth(sub) + 2);
      if (innerNeeded > w) w = innerNeeded;
    }
    colW[c] = w > _boxMaxW ? _boxMaxW : w;
  }

  // Column x-positions.
  final colX = List<int>.filled(cols.length, 0);
  for (var c = 1; c < cols.length; c++) {
    colX[c] = colX[c - 1] + colW[c - 1] + _colGap;
  }

  // Per-node top-left + center.
  final topLeft = <String, ({int row, int col})>{};
  final centers = <String, NodeCenter>{};
  for (var c = 0; c < cols.length; c++) {
    for (var i = 0; i < cols[c].length; i++) {
      final id = cols[c][i];
      final row = i * (_boxH + _rowGap);
      final col = colX[c];
      topLeft[id] = (row: row, col: col);
      centers[id] = NodeCenter(row + (_boxH ~/ 2), col + colW[c] ~/ 2);
    }
  }

  final width = cols.isEmpty
      ? 0
      : colX.last + colW.last + _colGap;
  final mainHeight = cols.isEmpty
      ? 0
      : cols.fold<int>(0, (m, c) => c.length * (_boxH + _rowGap) > m ? c.length * (_boxH + _rowGap) : m);

  final grid = _Grid(width, mainHeight);

  // Stamp node boxes.
  for (var c = 0; c < cols.length; c++) {
    for (final id in cols[c]) {
      _stampBox(grid, g.node(id)!, topLeft[id]!, colW[c],
          selected: id == selectedId, status: status?[id]);
    }
  }

  // Forward edges (rank increases): L-connectors through the gutter.
  for (final e in g.edges) {
    if (lo.backEdges.contains(_edgeKey(e.from, e.to))) continue;
    if (!topLeft.containsKey(e.from) || !topLeft.containsKey(e.to)) continue;
    _routeForward(grid, g, e, topLeft, colW, centers);
  }

  final lines = <String>[];
  for (var r = 0; r < grid.height; r++) {
    lines.add(grid.rowString(r));
  }

  // Back-edge band: labeled, beneath the graph, so loops stay visible without
  // colliding with forward flow.
  final back = g.edges
      .where((e) => lo.backEdges.contains(_edgeKey(e.from, e.to)))
      .where((e) => topLeft.containsKey(e.from) && topLeft.containsKey(e.to))
      .toList();
  if (back.isNotEmpty) {
    if (lines.isNotEmpty) lines.add('');
    lines.add('loops:');
    for (final e in back) {
      final arrow = e.label.isNotEmpty ? '◀── ${e.label} ──' : '◀──';
      lines.add('  ${g.node(e.from)?.label ?? e.from}  $arrow  '
          '${g.node(e.to)?.label ?? e.to}');
    }
  }

  return RenderResult(lines, centers);
}

String? _subLine(PipelineNode n) {
  if (n.llmModel.isNotEmpty) return n.llmModel;
  if (n.handlerType != 'codergen') return n.handlerType;
  return null;
}

void _stampBox(_Grid grid, PipelineNode n, ({int row, int col}) tl, int w,
    {required bool selected, NodeRunStatus? status}) {
  final inner = w - 2;
  final markAt = n.goalGate ? inner ~/ 2 : -1;
  String topBottom(String left, String right) {
    final buf = StringBuffer(left);
    for (var i = 0; i < inner; i++) {
      buf.write(i == markAt ? '◆' : '─');
    }
    buf.write(right);
    return buf.toString();
  }

  // Selection (double box) wins over a status border; they never co-occur in
  // the shipped surfaces (the editor selects, the run panel tracks status).
  final (tl_c, tr_c, bl_c, br_c, side) = selected
      ? ('╔', '╗', '╚', '╝', '║')
      : switch (status) {
          NodeRunStatus.running => ('┏', '┓', '┗', '┛', '┃'),
          NodeRunStatus.done => ('╭', '╮', '╰', '╯', '│'),
          NodeRunStatus.failed => ('╔', '╗', '╚', '╝', '║'),
          _ => ('┌', '┐', '└', '┘', '│'), // pending / skipped / null
        };

  final label = _fit(n.label, inner);
  final sub = _subLine(n);
  final subLine = sub == null ? '' : _fit(sub, inner);

  grid.write(tl.row, tl.col, topBottom(tl_c, tr_c));
  grid.write(tl.row + 1, tl.col, '$side$label$side');
  grid.write(tl.row + 2, tl.col, '$side$subLine$side');
  grid.write(tl.row + 3, tl.col, topBottom(bl_c, br_c));
}

void _routeForward(_Grid grid, Graph g, PipelineEdge e,
    Map<String, ({int row, int col})> tl, List<int> colW,
    Map<String, NodeCenter> centers) {
  final u = centers[e.from]!;
  final v = centers[e.to]!;
  final uRight = tl[e.from]!.col + colW[_colOf(tl, e.from, colW)] - 1;
  final vLeft = tl[e.to]!.col;

  // Horizontal out of the source's right, into the gutter.
  final startRow = u.row;
  final endRow = v.row;
  final arrowCol = vLeft - 1;

  // Walk right from uRight+1 to arrowCol along startRow, drawing ─.
  for (var c = uRight + 1; c < arrowCol; c++) {
    grid.merge(startRow, c, '─');
  }
  // Vertical segment in the gutter (at arrowCol) from startRow to endRow.
  if (startRow != endRow) {
    final lo = math.min(startRow, endRow);
    final hi = math.max(startRow, endRow);
    for (var r = lo + 1; r < hi; r++) {
      grid.merge(r, arrowCol, '│');
    }
    // Bends at the turns.
    grid.merge(startRow, arrowCol, startRow < endRow ? '┐' : '┘');
    grid.merge(endRow, arrowCol, startRow < endRow ? '└' : '┌');
  }
  // Arrowhead into the target.
  grid.merge(endRow, arrowCol, '▶');
  for (var c = arrowCol + 1; c < vLeft; c++) {
    grid.merge(endRow, c, '─');
  }
}

int _colOf(Map<String, ({int row, int col})> tl, String id, List<int> colW) {
  // Recover column index from a node's left x by matching colW stride — cheap:
  // recompute from tl col. We don't have rank handy here, so derive from x.
  final x = tl[id]!.col;
  var c = 0, acc = 0;
  while (c < colW.length && acc + colW[c] <= x) {
    acc += colW[c] + _colGap;
    c++;
  }
  return c >= colW.length ? colW.length - 1 : c;
}

String _fit(String s, int w) {
  final dw = _displayWidth(s);
  if (dw == w) return s;
  if (dw > w) return '${s.substring(0, w - 1)}…';
  final pad = (w - dw) ~/ 2;
  return '${' ' * pad}$s${' ' * (w - dw - pad)}';
}

int _displayWidth(String s) => s.length; // graph labels are plain ASCII for now

String _edgeKey(String from, String to) => '$from\x00$to';

/// A growable character grid that merges edge glyphs over spaces without
/// clobbering node-box borders.
class _Grid {
  final List<List<String>> _cells;
  final int width;
  int height;
  _Grid(this.width, int minRows)
      : _cells = [
          for (var r = 0; r < math.max(minRows, 1); r++) _blank(math.max(width, 1))
        ],
        height = math.max(minRows, 1);

  static List<String> _blank(int w) => [for (var i = 0; i < w; i++) ' '];

  void write(int row, int col, String text) {
    _ensure(row, col + text.length);
    for (var i = 0; i < text.length; i++) {
      _cells[row][col + i] = text[i];
    }
  }

  /// Place [ch] only if the cell is space (edges never overwrite boxes/other
  /// edges). Arrowheads/bends are forced so they win over a stray `─`.
  void merge(int row, int col, String ch) {
    _ensure(row, col + 1);
    final cur = _cells[row][col];
    if (cur == ' ' || _force(ch)) {
      _cells[row][col] = ch;
    }
  }

  static bool _force(String ch) => ch == '▶' || ch == '◆';

  void _ensure(int row, int col) {
    while (height <= row) {
      _cells.add(_blank(width));
      height++;
    }
  }

  String rowString(int row) => _cells[row].join();
}
