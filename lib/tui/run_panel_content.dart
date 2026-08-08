import 'package:attractor/attractor.dart';
import 'package:tina_console/tina_console.dart';

import '../pipeline/workflow_supervisor.dart';

/// The live view of one background workflow run, presented in a right-column
/// [PanelFrame] like a spawned agent panel. Shows:
///
///   * a status line (RUNNING/COMPLETED/FAILED/CANCELLED + node tally);
///   * a pannable ASCII slice of the workflow graph, whose node borders carry
///     run-state glyphs (heavy = running, rounded = done, double = failed);
///   * a colored per-node status list (layout order);
///   * a legend with the `s` (stop) / `x` (close) hints.
///
/// Paints itself with `putAtAbsolute` into its frame interior (no surface —
/// [PanelContent] defaults). Rows are built plain, truncated/padded by display
/// width, then colorized — so clipping never splits an SGR sequence. The pure
/// line builder [buildLines] is the unit test seam; [updateStatus] re-renders
/// from [WorkflowRun.nodeStatus] on every engine event.
class RunPanelContent implements PanelContent {
  RunPanelContent({
    required this.screen,
    required Graph? graph,
    required this.run,
    this.error,
  })  : _graph = graph,
        _layout = graph == null ? null : computeLayout(graph),
        _orderedIds = graph == null
            ? const <String>[]
            : computeLayout(graph).ranks.expand((r) => r).toList();

  final Screen screen;
  final Graph? _graph;
  final NodeLayout? _layout;
  final List<String> _orderedIds;
  final WorkflowRun run;

  /// Why the graph is unavailable (a deleted/unparseable `.dot`); the panel
  /// renders an error line instead of the graph.
  final String? error;

  Rect _interior = Rect.empty;
  int _panRow = 0;
  int _panCol = 0;

  // Cached render of the graph with the current status map; rebuilt by
  // [updateStatus]. The layout itself is stable for the run's lifetime.
  List<String> _lines = const [];

  // -- PanelContent --------------------------------------------------------

  @override
  bool get isDetached => false; // we paint directly; nothing to detach from

  @override
  BackendSurface? get surface => null;

  @override
  void bindSurface(BackendSurface? s) {
    // No owned surface — the content paints via the standard plane.
  }

  @override
  void fit(Rect interior, {required bool reserveInputRow}) {
    _interior = interior;
    _paint();
  }

  @override
  void attach() => _paint();

  @override
  void detach() {
    // Erase our rows; a repaint on the next attach/fit redraws everything.
    final b = _interior;
    if (b.isEmpty) return;
    for (var r = 0; r < b.height; r++) {
      screen.eraseAtAbsolute(
        row: b.row + r,
        col: b.col,
        n: b.width,
        moveCursor: false,
        clipRect: b,
      );
    }
  }

  // -- Keys (panning; 's'/'x' are claimed by the coordinator's onPanelKey) --

  /// Arrow keys pan the graph viewport. Returns true when consumed.
  bool handleKey(InputEvent ev) {
    if (ev is! ArrowKey) return false;
    if (_lines.isEmpty || _interior.isEmpty) return false;
    final rows = _graphRows(_interior.height);
    final maxLine = _lines.fold<int>(0, (m, s) => s.length > m ? s.length : m);
    switch (ev.direction) {
      case ArrowDirection.up:
        _panRow -= 1;
      case ArrowDirection.down:
        _panRow += 1;
      case ArrowDirection.left:
        _panCol -= 3;
      case ArrowDirection.right:
        _panCol += 3;
      case ArrowDirection.pageUp:
        _panRow -= rows;
      case ArrowDirection.pageDown:
        _panRow += rows;
    }
    final maxRow = _lines.length - rows;
    _panRow = _panRow.clamp(0, maxRow.clamp(0, 1 << 30));
    _panCol = _panCol.clamp(0, (maxLine - _interior.width).clamp(0, 1 << 30));
    _paint();
    return true;
  }

  // -- Run updates ---------------------------------------------------------

  /// Re-render the graph with the run's current per-node status and repaint.
  void updateStatus() {
    final graph = _graph;
    _lines = graph == null
        ? const <String>[]
        : renderGraph(graph, layout: _layout, status: run.nodeStatus).lines;
    _paint();
  }

  // -- Rendering -----------------------------------------------------------

  /// Rows of the frame interior reserved for the graph viewport: the status
  /// line (1) + legend (1) are fixed; the status list gets up to 2/3 of the
  /// remainder, the graph the rest. Takes [h] so the pure [buildLines] seam
  /// doesn't depend on the (possibly unfitted) interior.
  int _graphRows(int h) {
    if (h <= 0) return 0;
    final remaining = h - 2;
    final listBudget = (_orderedIds.length * 2 / 3).ceil().clamp(0, remaining);
    return _lines.length.clamp(0, remaining - listBudget);
  }

  /// Pure line builder: [w]×[h] rows for the current state. Rows are plain
  /// text (color applied per row at the end), so truncation/padding never
  /// splits an ANSI sequence.
  List<String> buildLines(int w, int h) {
    if (w <= 0 || h <= 0) return const [];

    final theme = screen.theme.chat;
    final out = <String>[];

    // 1. Status line.
    final doneCount = run.nodeStatus.values
        .where((s) => s != NodeRunStatus.pending)
        .length;
    final (label, code) = switch (run.status) {
      WorkflowRunStatus.running =>
        ('RUNNING · $doneCount/${_orderedIds.length} nodes', theme.cyan),
      WorkflowRunStatus.completed =>
        ('COMPLETED · $doneCount/${_orderedIds.length} nodes', theme.green),
      WorkflowRunStatus.failed =>
        ('FAILED · $doneCount/${_orderedIds.length} nodes', theme.red),
      WorkflowRunStatus.cancelled =>
        ('CANCELLED · $doneCount/${_orderedIds.length} nodes', theme.dim),
    };
    out.add(_colorize(code, _fit(label, w)));

    // 2. Graph viewport (panned slice).
    final graphH = _graphRows(h);
    for (var r = 0; r < graphH; r++) {
      final src = _panRow + r < 0 || _panRow + r >= _lines.length
          ? ''
          : _lines[_panRow + r];
      out.add(_crop(src, _panCol, w));
    }

    // 3. Status list — layout order, colored per status.
    final listRows = h - 2 - graphH;
    for (var i = 0; i < listRows && i < _orderedIds.length; i++) {
      final id = _orderedIds[i];
      final status = run.nodeStatus[id] ?? NodeRunStatus.pending;
      final (glyph, statusCode) = switch (status) {
        NodeRunStatus.pending => ('·', null),
        NodeRunStatus.running => ('▶', theme.cyan),
        NodeRunStatus.done => ('✔', theme.green),
        NodeRunStatus.failed => ('✖', theme.red),
        NodeRunStatus.skipped => ('↷', theme.yellow),
      };
      final row = _fit('  $glyph $id', w);
      out.add(statusCode == null ? row : _colorize(statusCode, row));
    }

    // 4. Legend (last row).
    final legend =
        error ?? '▶ run · ✔ done · ✖ failed · ↷ skip · s stop · x close';
    out.add(_colorize(theme.dim, _fit(legend, w)));

    return out;
  }

  void _paint() {
    final b = _interior;
    if (b.isEmpty) return;
    final lines = buildLines(b.width, b.height);
    for (var r = 0; r < b.height; r++) {
      if (r < lines.length) {
        screen.putAtAbsolute(
          row: b.row + r,
          col: b.col,
          text: lines[r],
          maxCols: b.width,
          moveCursor: false,
          clipRect: b,
        );
      } else {
        screen.eraseAtAbsolute(
          row: b.row + r,
          col: b.col,
          n: b.width,
          moveCursor: false,
          clipRect: b,
        );
      }
    }
  }

  String _colorize(String code, String text) => screen.colorize(code, text);

  /// Truncate/pad a PLAIN string to exactly [w] display columns.
  static String _fit(String s, int w) {
    if (s.length <= w) return s.padRight(w);
    return s.substring(0, w);
  }

  /// A [w]-column window into [s] at display column [col]. [s] is plain
  /// (graph lines carry no ANSI), so code-unit length == display width.
  static String _crop(String s, int col, int w) {
    if (col >= s.length) return ' ' * w;
    final out = col < 0
        ? ' ' * (-col).clamp(0, w) + s.substring(0, s.length.clamp(0, w + col))
        : s.substring(col);
    return out.length >= w ? out.substring(0, w) : out.padRight(w);
  }
}
