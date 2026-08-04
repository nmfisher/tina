import 'backend/backend_surface.dart';
import 'focusable.dart';
import 'rect.dart';
import 'region.dart';
import 'screen.dart';

/// A [Region] that is also [Focusable] and backed by its own [BackendSurface].
///
/// `Panel` is the reusable building block for tiled or floating UI areas: it
/// combines the output discipline of [Region] (bounded writes, content
/// retention) with the input discipline of [Focusable] (receives events when
/// focused), and owns a backend surface so it can be independently shown,
/// hidden, moved, resized, and z-ordered.
///
/// Concrete panels populate [rows] (one string per row, clipped to
/// [bounds].width) and call [redraw] to paint. They implement [handleEvent]
/// to react to input while focused. See [TextPanel] for a minimal example.
///
/// Lifecycle:
/// - [mount] creates the backend surface and paints initial content.
/// - [show]/[hide] toggle visibility (content is retained across hides).
/// - [moveTo]/[resize] change geometry and repaint.
/// - [unmount] releases the surface.
abstract class Panel extends Region implements Focusable {
  Rect _bounds;

  /// The backend surface backing this panel, or `null` before [mount].
  BackendSurface? _surface;

  bool _hasFocus = false;
  bool _visible = true;

  /// Retained content: one string per row, indexed 0..height-1. Subclasses
  /// write here then call [redraw]. Kept in sync with [bounds].height by
  /// [resize].
  final List<String> rows;

  Panel(Screen screen, Rect bounds)
      : _bounds = bounds,
        rows = List<String>.filled(bounds.height < 0 ? 0 : bounds.height, '',
            growable: true),
        super(screen);

  @override
  Rect get bounds => _bounds;

  BackendSurface? get surface => _surface;
  bool get isMounted => _surface != null;
  bool get isVisible => _visible;

  @override
  bool get hasFocus => _hasFocus;

  @override
  bool get canFocus => _visible && isMounted;

  // -- Lifecycle ----------------------------------------------------------

  /// Create the backend surface and paint initial content. Idempotent.
  void mount() {
    if (_surface != null) return;
    _surface = screen.createSurface(_bounds);
    redraw();
  }

  /// Release the backend surface. Idempotent.
  void unmount() {
    _surface?.destroy();
    _surface = null;
  }

  // -- Focus --------------------------------------------------------------

  @override
  void focus() {
    if (_hasFocus) return;
    _hasFocus = true;
    _surface?.raiseToTop();
    onFocusChanged();
  }

  @override
  void blur() {
    if (!_hasFocus) return;
    _hasFocus = false;
    onFocusChanged();
  }

  /// Called after focus changes. Default re-renders so a subclass can reflect
  /// focus in its frame. Override to do more.
  void onFocusChanged() => redraw();

  @override
  void highlight() {
    // Generic panels don't participate in the box-tint cycling cue.
  }

  @override
  void unhighlight() {}

  // -- Geometry -----------------------------------------------------------

  /// Move the panel origin to absolute ([row], [col]) and repaint.
  void moveTo(int row, int col) {
    _bounds =
        Rect(row: row, col: col, width: _bounds.width, height: _bounds.height);
    _surface?.moveTo(row, col);
    redraw();
  }

  /// Resize to [width] x [height] and repaint. Adjusts [rows] to the new
  /// height (truncating or padding with blanks).
  void resize(int width, int height) {
    _bounds =
        Rect(row: _bounds.row, col: _bounds.col, width: width, height: height);
    _reconcileRows();
    _surface?.resize(width, height);
    redraw();
  }

  // -- Visibility ---------------------------------------------------------

  /// Show the panel: repaint retained content. No-op if already visible.
  void show() {
    if (_visible) return;
    _visible = true;
    redraw();
  }

  /// Hide the panel: erase its area. Content is retained; call [show] to
  /// restore. A hidden panel is not focusable.
  void hide() {
    if (!_visible) return;
    _visible = false;
    if (_hasFocus) blur();
    _eraseArea();
  }

  // -- Rendering ----------------------------------------------------------

  /// Repaint every retained row. No-op if unmounted or hidden.
  void redraw() => screen.frame(() {
        final s = _surface;
        if (s == null || !_visible) return;
        for (var r = 0; r < _bounds.height; r++) {
          _emitRow(s, r);
        }
      });

  void _emitRow(BackendSurface s, int relRow) {
    s.putAt(
      relRow: relRow,
      relCol: 0,
      text: relRow < rows.length ? rows[relRow] : '',
      maxCols: _bounds.width,
      moveCursor: false,
    );
  }

  void _eraseArea() => screen.frame(() {
        final s = _surface;
        if (s == null) return;
        for (var r = 0; r < _bounds.height; r++) {
          s.eraseAt(relRow: r, relCol: 0, n: _bounds.width, moveCursor: false);
        }
      });

  void _reconcileRows() {
    final h = _bounds.height < 0 ? 0 : _bounds.height;
    // Shrink keeps the top rows (panels are top-anchored); grow pads blanks
    // at the bottom. (ChatRegion drops from the front because chat scrolls —
    // panels don't.)
    if (rows.length > h) {
      rows.removeRange(h, rows.length);
    } else if (rows.length < h) {
      rows.addAll(List<String>.filled(h - rows.length, ''));
    }
  }

  @override
  void handleResize() {
    // Subclasses with host-driven geometry should override to recompute
    // [bounds] (via moveTo/resize) before falling back to redraw().
    redraw();
  }
}
