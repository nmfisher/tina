import 'backend/backend_surface.dart';
import 'comet.dart';
import 'focusable.dart';
import 'input_event.dart';
import 'rect.dart';
import 'screen.dart';

/// A focusable chrome frame: a bordered box with a title bar and an optional
/// busy (turn-in-flight) comet. It owns only rectangles and focus state — it
/// knows nothing about the content it frames.
///
/// Every conversation — the primary chat and each spawned one — is wrapped in
/// a `PanelFrame` whose interior holds a [PanelContent] (today a
/// [ScrollingTextRegion] via [ChatRegionPanelContent]). The wrapped content's
/// [bounds] are the box *interior*, so streaming content never touches the
/// self-drawn border and the border never clobbers content. Content positioning
/// lives in the adapter, not here, so this frame can host any surface.
///
/// The busy cue is a comet that sweeps the top and bottom rails while [setBusy]
/// is on, driven by a per-panel timer; the border also tints cyan. Focus tints
/// the border cyan; the cycling highlight tints it yellow. See [comet.dart] for
/// the cell math.
///
/// Per the spawn-unification "Option 1" input model there is a single shared
/// input line; a side panel shows scrollback only and [handleEvent] returns
/// false so keystrokes fall through to the line editor.
class PanelFrame implements Focusable {
  final Screen screen;

  /// Conversation label shown in the title bar (a provider/model ref).
  /// Updatable — call [relabel] to change and re-render.
  String _label;
  String get label => _label;

  /// Replace the label and repaint the panel chrome. The framed content is
  /// untouched (it's a separate surface). Use this when `/model` changes the
  /// active conversation's provider/model reference.
  void relabel(String newLabel) {
    _label = newLabel;
    render();
  }

  /// Conversation id this panel represents — used by the coordinator to make
  /// the conversation active when this panel is focused, and to look up its
  /// [PanelContent] adapter. Retained here pending Phase 5's conversation→frame
  /// binding map, which will move this identity out of the chrome class.
  final String conversationId;

  /// Fired whenever this panel gains focus, so the coordinator can make its
  /// conversation the active input target. Set by the coordinator.
  void Function()? onFocus;

  /// Fired when the user scrolls the framed chat with PgUp/PgDn: −1 for a
  /// page up (back into history), +1 for a page down (toward the tail). Set by
  /// the coordinator to route the scroll to this panel's chat region. null
  /// (the default) leaves PgUp/PgDn unclaimed (they fall through to the editor).
  void Function(int deltaPages)? onScroll;

  /// Optional per-panel key handler, consulted first by [handleEvent]. Set by
  /// the coordinator for non-chat content (e.g. a workflow run panel's
  /// pan/stop/close keys); null (the default) keeps the historical
  /// PgUp/PgDn-only behavior for conversation panels.
  bool Function(InputEvent event)? onPanelKey;

  /// Per-step cadence of the busy comet. Each tick advances the head one cell;
  /// ~40ms gives a brisk sweep without flickering.
  static const Duration busyTickDuration = Duration(milliseconds: 40);

  PanelFrame({
    required this.screen,
    required String label,
    required this.conversationId,
    bool ownsCanvas = false,
  })  : _label = label,
        _ownsCanvas = ownsCanvas;

  Rect _outer = Rect.empty;
  bool _hasFocus = false;
  bool _isHighlighted = false;
  bool _busy = false;
  int _busyTick = 0;
  bool _busyAnimationRegistered = false;

  /// "↓ N new" badge: the count of chat lines that arrived while the panel was
  /// scrolled up. Rendered right-aligned on the bottom rail; 0 hides it.
  int _scrollBadge = 0;

  /// Whether this frame owns the chat's [BackendSurface] (the
  /// frame-owns-canvas model). When false the framed region owns its own
  /// surface (legacy); when true the frame creates and sizes the surface and
  /// the region borrows it, so geometry flows one way (frame → surface →
  /// region) and can't go stale. Default false keeps the legacy model until
  /// the coordinator opts spawned panels in.
  final bool _ownsCanvas;

  /// The chat surface this frame owns when [_ownsCanvas]. null otherwise, or
  /// when the backend can't provide one (the region then falls back to its own
  /// surface or the absolute path).
  BackendSurface? _surface;
  bool _surfaceFailed = false;

  /// The chat surface this frame owns, for the coordinator to hand the framed
  /// region via `bindSurface`. null when the frame doesn't own a canvas.
  BackendSurface? get surface => _surface;

  /// Per-panel input state, saved/restored by the coordinator on focus change
  /// so typed-but-unsent text persists when navigating between panels.
  String inputBuffer = '';
  int inputCursor = 0;

  /// Whether the bottom interior row is currently reserved for the shared
  /// input line (so the framed content keeps its full height but shifts its
  /// content up by one row — a display-only shift, never a buffer resize).
  bool _reservesInput = false;

  /// The full panel rectangle including the self-drawn border.
  @override
  Rect get bounds => _outer;

  @override
  bool get hasFocus => _hasFocus;

  @override
  bool get canFocus => !bounds.isEmpty;

  // -- Focusable ---------------------------------------------------------

  @override
  void focus() {
    _hasFocus = true;
    _isHighlighted = false;
    // (The chat-surface raise that used to live here moved to the coordinator's
    // onPanelFocused: a panel is content-agnostic and must not touch a chat.)
    render();
    onFocus?.call();
  }

  @override
  void blur() {
    _hasFocus = false;
    render();
  }

  @override
  void highlight() {
    _isHighlighted = true;
    render();
  }

  @override
  void unhighlight() {
    _isHighlighted = false;
    // Always repaint: the panel losing the highlight while cycling is usually
    // *not* focused, so a `_hasFocus` guard here would leave its stale yellow
    // border on screen (multiple panels yellow at once).
    render();
  }

  @override
  bool handleEvent(InputEvent event) {
    // A non-chat panel (e.g. a workflow run view) can claim keys first via
    // [onPanelKey]; returning true consumes the event before the editor.
    if (onPanelKey != null && onPanelKey!(event)) return true;
    // PgUp/PgDn scroll this panel's chat history (when the coordinator wired
    // [onScroll]). −1 = back into history, +1 = toward the tail. Unclaimed
    // (no onScroll) or other events fall through to the line editor.
    if (event is ArrowKey) {
      final cb = onScroll;
      if (cb != null) {
        if (event.direction == ArrowDirection.pageUp) {
          cb(-1);
          return true;
        }
        if (event.direction == ArrowDirection.pageDown) {
          cb(1);
          return true;
        }
      }
    }
    return false;
  }

  // -- Chrome ------------------------------------------------------------

  /// Toggle the busy (turn-in-flight) cue. When on, a comet sweeps the top and
  /// bottom rails (driven by a per-panel timer) and the border tints cyan.
  void setBusy(bool busy) {
    if (_busy == busy) return;
    _busy = busy;
    if (busy) {
      _busyTick = 0;
      if (!screen.passthrough && !_busyAnimationRegistered) {
        screen.registerAnimation(_advanceBusyAnimation,
            interval: busyTickDuration);
        _busyAnimationRegistered = true;
      }
    } else {
      _unregisterBusyAnimation();
    }
    render();
  }

  /// Advance the busy comet by one step and repaint the rails. Exposed so
  /// tests can step the animation deterministically without waiting on
  /// [busyTickDuration].
  void advanceBusyTick() {
    final previousTick = _busyTick;
    _busyTick++;
    _repaintBusyRailDelta(previousTick);
  }

  void _advanceBusyAnimation() {
    final previousTick = _busyTick;
    _busyTick++;
    _repaintBusyRailDelta(previousTick);
  }

  void _unregisterBusyAnimation() {
    if (!_busyAnimationRegistered) return;
    screen.unregisterAnimation(_advanceBusyAnimation);
    _busyAnimationRegistered = false;
  }

  /// Set the "↓ N new" scrollback badge count and repaint the bottom rail when
  /// it changes. 0 (or negative) clears it. Driven by the region's
  /// [ScrollingTextRegion.onScrollbackChanged] via the coordinator.
  void setScrollBadge(int n) {
    final clamped = n < 0 ? 0 : n;
    if (_scrollBadge == clamped) return;
    _scrollBadge = clamped;
    render();
  }

  /// Release the busy timer. Called by the coordinator on spawned-panel close
  /// and on teardown.
  void dispose() {
    _unregisterBusyAnimation();
    _surface?.destroy();
    _surface = null;
  }

  /// The rect the owned surface covers: [interior] minus the reserved input
  /// row when one is in effect (the input row lives on the standard plane,
  /// below the surface — matching the region's usable-height semantics).
  Rect get _contentRect {
    final i = interior;
    final h = _reservesInput && i.height > 0 ? i.height - 1 : i.height;
    return Rect(row: i.row, col: i.col, width: i.width, height: h);
  }

  /// Create or resize the owned chat surface to match [_contentRect]. A
  /// backend that can't provide a surface (test fakes, notcurses alloc
  /// failure) throws and is remembered so we don't retry; the region then
  /// falls back. No-op when the frame doesn't own a canvas. Resize+move
  /// preserve the underlying plane identity, which native scroll depends on.
  void _ensureFrameSurface() {
    if (!_ownsCanvas || screen.passthrough) return;
    final r = _contentRect;
    if (r.isEmpty || _surfaceFailed) return;
    if (_surface != null) {
      if (_surface!.bounds != r) {
        _surface!.resize(r.width, r.height);
        _surface!.moveTo(r.row, r.col);
      }
      return;
    }
    try {
      _surface = screen.createSurface(r);
    } catch (_) {
      _surfaceFailed = true;
      return;
    }
    screen.adoptChatSurface(_surface!);
  }

  /// Assign the panel's outer rectangle (border inclusive) and repaint the
  /// chrome. Content positioning is the [PanelContent] adapter's job and is
  /// driven by the coordinator (which calls `adapter.fit(interior, ...)` after
  /// this). Called by the coordinator after layout changes.
  void setOuter(Rect outer) {
    _outer = outer;
    _ensureFrameSurface();
    render();
  }

  /// The content rectangle: [bounds] inset by the 1-cell border this frame
  /// draws. The content adapter positions its surface here; when the bottom row
  /// is reserved for the shared input line it applies a bottom inset rather
  /// than shrinking this rect.
  Rect get interior {
    final b = _outer;
    final interiorW = b.width > 2 ? b.width - 2 : 1;
    final interiorH = b.height > 2 ? b.height - 2 : 1;
    return Rect(row: b.row + 1, col: b.col + 1, width: interiorW, height: interiorH);
  }

  /// The rectangle the shared input line should occupy when this panel is the
  /// active input target — the bottom interior row. Returns [Rect.empty] when
  /// the panel is too small to host an input row (under three rows or cols).
  Rect get inputRect {
    final b = _outer;
    if (b.height < 3 || b.width < 3) return Rect.empty;
    return Rect(
      row: b.bottom - 1,
      col: b.col + 1,
      width: b.width - 2,
      height: 1,
    );
  }

  /// Whether the bottom interior row is currently reserved for the shared
  /// input line (so the framed content keeps its full height but shifts its
  /// content up by one row — a display-only shift, never a buffer resize).
  bool get reservesInput => _reservesInput;

  /// Reserve (or release) the bottom interior row for the shared input line.
  /// The framed content's bottom inset is the adapter's responsibility (it
  /// shifts content up by one row, a display-only shift), so this only flips
  /// the flag and repaints the chrome.
  void setReservesInput(bool reserve) {
    if (_reservesInput == reserve) return;
    _reservesInput = reserve;
    _ensureFrameSurface();
    render();
  }

  String? get _accent {
    if (_isHighlighted)
      return screen.theme.border.selection; // yellow (cycling)
    if (_hasFocus) return screen.theme.border.focus; // cyan
    if (_busy) return null; // plain border with comet — unfocused
    return null;
  }

  String _paint(String s, String? accent) =>
      accent == null ? s : screen.colorize(accent, s);

  /// The styled top border string: `┌<title><fill>┐`. The fill carries the
  /// comet (shifted so it sweeps opposite the bottom) when busy.
  String _topRow() {
    final b = _outer;
    final w = b.width;
    final innerW = w > 2 ? w - 2 : 1;
    final accent = _accent;
    final titleArea =
        label.length > innerW ? label.substring(0, innerW) : label;
    final padLen = innerW - titleArea.length;
    final fill = _busy
        ? cometRailString(
            screen.theme, padLen, _busyTick, accent, screen.colorize,
            shift: true)
        : _paint('─' * (padLen < 0 ? 0 : padLen), accent);
    return '${_paint('┌', accent)}${_paint(titleArea, accent)}$fill${_paint('┐', accent)}';
  }

  /// The styled bottom border string: `└<fill>┘`. The fill carries the comet
  /// sweeping the full inner width when busy; when a scrollback badge is set
  /// ("↓ N new") it sits right-aligned on the rail and the comet/rule fills
  /// the remaining width to its left.
  String _bottomRow() {
    final b = _outer;
    final w = b.width;
    final innerW = w > 2 ? w - 2 : 1;
    final accent = _accent;
    final badge = _scrollBadge > 0 ? '↓ $_scrollBadge new' : null;
    final badgeCells = badge?.length ?? 0; // all single-width glyphs
    if (badge != null) {
      final leftW = innerW > badgeCells ? innerW - badgeCells : 0;
      final left = _busy && leftW > 0
          ? cometRailString(
              screen.theme, leftW, _busyTick, accent, screen.colorize)
          : _paint('─' * (leftW < 0 ? 0 : leftW), accent);
      final shown = badgeCells > innerW ? badge.substring(0, innerW) : badge;
      return '${_paint('└', accent)}$left${_paint(shown, accent)}${_paint('┘', accent)}';
    }
    final fill = _busy
        ? cometRailString(
            screen.theme, innerW, _busyTick, accent, screen.colorize)
        : _paint('─' * innerW, accent);
    return '${_paint('└', accent)}$fill${_paint('┘', accent)}';
  }

  @override
  String toString() => 'PanelFrame($conversationId)';

  /// Paint the bordered box: top border with label title, vertical sides,
  /// bottom border, and the per-panel input row at the bottom interior.
  void render() => screen.frame(() {
        final b = _outer;
        if (b.isEmpty) return;

        _write(b.row, b.col, _topRow(), b.width);

        // Sides: │ ... │ (skip when too short to have an interior row).
        final accent = _accent;
        final side = _paint('│', accent);
        for (var r = b.row + 1; r < b.bottom; r++) {
          _write(r, b.col, side, 1);
          _write(r, b.right, side, 1);
        }

        _write(b.bottom, b.col, _bottomRow(), b.width);
        _renderInputRow();
      });

  /// Paint the per-panel input text at the bottom interior row. For the
  /// focused panel the editor's [screen.input] paints on top with cursor
  /// positioning; for unfocused panels this is the only input rendering.
  void _renderInputRow() {
    final b = _outer;
    if (b.isEmpty || b.height < 3) return;
    final row = b.bottom - 1;
    final col = b.col + 1;
    final width = b.width - 2;
    if (width <= 0) return;
    if (inputBuffer.isEmpty && !_hasFocus) return;
    final prompt = _hasFocus ? '> ' : '';
    final maxBuf = width - prompt.length;
    final buf = inputBuffer.length > maxBuf
        ? inputBuffer.substring(inputBuffer.length - maxBuf)
        : inputBuffer;
    screen.putAtAbsolute(
      row: row,
      col: col,
      text: '$prompt$buf',
      maxCols: width,
      moveCursor: false,
      clipRect: b,
    );
  }

  /// Repaint only the runs whose comet cells changed between ticks. The comet
  /// tail is short, so this keeps animation work independent of panel width.
  void _repaintBusyRailDelta(int previousTick) => screen.frame(() {
        final b = _outer;
        if (b.isEmpty) return;
        final innerW = b.width > 2 ? b.width - 2 : 1;
        final titleWidth = label.length > innerW ? innerW : label.length;
        _repaintCometRuns(
          row: b.row,
          col: b.col + 1 + titleWidth,
          span: innerW - titleWidth,
          previousTick: previousTick,
          shift: true,
        );
        _repaintCometRuns(
          row: b.bottom,
          col: b.col + 1,
          span: innerW,
          previousTick: previousTick,
        );
      });

  void _repaintCometRuns({
    required int row,
    required int col,
    required int span,
    required int previousTick,
    bool shift = false,
  }) {
    if (span <= 0) return;
    final oldCells = cometRailCells(
      screen.theme,
      span,
      previousTick,
      shift: shift,
    );
    final newCells = cometRailCells(
      screen.theme,
      span,
      _busyTick,
      shift: shift,
    );
    var start = 0;
    while (start < span) {
      while (start < span && oldCells[start] == newCells[start]) {
        start++;
      }
      if (start == span) return;
      var end = start + 1;
      while (end < span && oldCells[end] != newCells[end]) {
        end++;
      }
      final text = StringBuffer();
      for (var i = start; i < end; i++) {
        final cell = newCells[i];
        final code = cell.code ?? _accent;
        text.write(
            code == null ? cell.glyph : screen.colorize(code, cell.glyph));
      }
      _write(row, col + start, text.toString(), end - start);
      start = end;
    }
  }

  void _write(int row, int col, String text, int maxCols) {
    screen.putAtAbsolute(
      row: row,
      col: col,
      text: text,
      maxCols: maxCols,
      moveCursor: false,
    );
  }
}
