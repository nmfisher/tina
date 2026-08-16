import 'dart:async';
import 'dart:typed_data';

import 'ansi_capable.dart';
import 'ansi_wrap.dart';
import 'backend/ansi_backend.dart';
import 'backend/backend_surface.dart';
import 'backend/terminal_backend.dart';
import 'rect.dart';
import 'region.dart';
import 'screen_layout.dart';
import 'stdio.dart';
import 'styled_text.dart';
import 'theme.dart';
import 'input_latency.dart';

/// The single sink + cursor + frame coordinator.
///
/// Every byte that reaches the terminal goes through here. Regions (chat,
/// status, input, overlays) hand text to the screen, which clips to their
/// bounds, delegates to a [TerminalBackend] for rendering, repaints
/// intersecting frame borders, and flushes the batched output.
///
/// Invariants enforced by this class:
///  - No code outside [Screen] (and its region subclasses) emits output.
///  - Every region write is clipped to its rectangle; nothing leaks.
///  - After any write that touches a border row, the border cells on that
///    row are re-emitted (so erase commands can't eat the frame).
///  - The visible terminal cursor is tracked here; regions ask for it,
///    they don't position it themselves.
/// The three bordered panels, for focus/highlight tinting.
enum FrameBox { chat, menu, info }

class Screen {
  final Stdio io;
  final AnsiCapable ansi;

  /// When true, all region writes pass straight through to [io] with no
  /// positioning, no row buffering, no frame. Used for `--prompt` runs and
  /// piped non-TTY output.
  final bool passthrough;

  /// Visual theme: SGR strings and RGB triples used by regions and the frame
  /// painter. Injected at construction so tests can override colors. Mutable
  /// via [setTheme] so background detection can swap the scheme at startup.
  Theme get theme => _theme;
  Theme _theme;

  ScreenLayout _layout;

  /// Backend for non-passthrough mode. Null when [passthrough] is true.
  final TerminalBackend? _backend;

  /// The chat region currently bound to the terminal. With multi-session,
  /// each session owns its own [ScrollingTextRegion]; switching repoints this via
  /// [setActiveChat]. Single-session callers just use the one created here.
  late ScrollingTextRegion _activeChat;
  late final StatusRegion _status;
  late final InputRegion _input;
  final List<OverlayRegion> _overlays = [];

  /// Surfaces that must stay above chat planes in the z-order, managed
  /// centrally so a focused chat plane being raised never buries the input
  /// row or a visible overlay. On notcurses these are real child planes;
  /// on ANSI they're emulated surfaces where raiseToTop is a no-op, so the
  /// bookkeeping is harmless there.
  BackendSurface? _inputSurface;
  BackendSurface? _activeChatSurface;
  final Set<BackendSurface> _chatSurfaces = {};
  final List<BackendSurface> _overlaySurfaces = [];

  bool _inAltScreen = false;
  Timer? _animationTimer;
  final Set<void Function()> _animations = {};

  // Phase 5: one monotonic clock + one trailing chat-coalescing timer for the
  // whole screen, replacing every ScrollingTextRegion's per-region _paintTimer.
  // _nanos is injectable so fake-async tests can drive the leading-edge idle
  // decision off the fake clock; production uses a monotonic Stopwatch.
  final int Function() _nanos;
  final int _chatWindowNanos; // coalescing window (8 ms)
  bool _chatEverPainted = false; // true once any chat presentation has run
  int _lastChatPaintNanos = 0; // nanos of last chat presentation
  Timer? _trailingChatTimer;
  final Set<ScrollingTextRegion> _pendingChatRegions = {};

  /// Nested [frame] depth. When > 0, leaf helpers defer border repair to
  /// [_pendingBorderRepairRows] instead of repairing immediately, so several
  /// writes to one row in a logical frame re-emit each border cell at most once.
  int _frameDepth = 0;
  final Set<int> _pendingBorderRepairRows = {};

  /// The cursor position the body most recently requested via [parkCursorAt]
  /// during the current outermost frame, if any. Border repairs run in the
  /// frame's [finally] (after the body), and each repair repositions the cursor
  /// onto a border cell; without re-parking, the body's requested cursor would
  /// be clobbered. Re-applied at the end of [_drainPendingBorderRepairs].
  int? _parkedRow;
  int? _parkedCol;

  /// Which box is the focused (input) panel — cyan border — and which is the
  /// cycling highlight — yellow border. Mutually exclusive per box. Driven by
  /// [focusFrame]/[highlightFrame]; read by the frame painter and per-write
  /// border repair so a tinted border survives ordinary region writes.
  FrameBox? _focusedBox;
  FrameBox? _highlightedBox;

  /// Canonical constructor holding the single copy of the init logic: the
  /// `ansi`/`theme` defaults and the three region wirings. The public
  /// constructors ([Screen] / [Screen.withBackend]) redirect here so the
  /// duplication that used to live across both is gone.
  Screen._({
    required this.io,
    required ScreenLayout layout,
    AnsiCapable? ansi,
    this.passthrough = false,
    Theme? theme,
    TerminalBackend? backend,
    int Function()? clock,
  })  : ansi = ansi ?? AnsiCapable.detect(),
        _theme = theme ?? const Theme.defaults(),
        _layout = layout,
        _backend = passthrough
            ? null
            : backend ??
                AnsiBackend(
                  io: io,
                  ansi: ansi ?? AnsiCapable.detect(),
                ),
        // Monotonic nanosecond clock. Production uses a Stopwatch (immune to
        // wall-clock jumps); tests inject the fake-async clock so the
        // leading-edge idle check advances with async.elapse. For chat timing
        // precision the Stopwatch granularity is more than enough.
        _nanos = clock ?? _monotonicNanos,
        _chatWindowNanos = const Duration(milliseconds: 8).inMicroseconds * 1000 {
    _activeChat = ScrollingTextRegion(this);
    _status = StatusRegion(this);
    _input = InputRegion(this);
  }

  Screen({
    required Stdio io,
    required ScreenLayout layout,
    AnsiCapable? ansi,
    bool passthrough = false,
    Theme? theme,
  }) : this._(
          io: io,
          layout: layout,
          ansi: ansi,
          passthrough: passthrough,
          theme: theme,
        );

  /// Create a Screen with an explicit [TerminalBackend].
  ///
  /// Use this when you want to select the rendering backend at runtime
  /// (e.g. notcurses instead of the default ANSI backend).
  Screen.withBackend({
    required TerminalBackend backend,
    required Stdio io,
    required ScreenLayout layout,
    AnsiCapable? ansi,
    Theme? theme,
    int Function()? clock,
  }) : this._(
          io: io,
          layout: layout,
          ansi: ansi,
          passthrough: false,
          theme: theme,
          backend: backend,
          clock: clock,
        );

  /// Monotonic nanosecond clock backed by [Stopwatch], independent of wall
  /// clock. Used only when no test clock is injected.
  static int _monotonicNanos() => _clock.elapsedMicroseconds * 1000;
  static final Stopwatch _clock = Stopwatch()..start();

  /// A Screen that writes plain text directly to [io] — no alt-screen, no
  /// frame, no region management. Use for `--prompt` and any non-TTY run.
  factory Screen.passthrough(Stdio io, {AnsiCapable? ansi, Theme? theme}) {
    return Screen(
      io: io,
      layout: ScreenLayout.fromSize(80, 24),
      ansi: ansi,
      passthrough: true,
      theme: theme,
    );
  }

  ScreenLayout get layout => _layout;

  /// The chat region currently bound to the terminal.
  ScrollingTextRegion get chat => _activeChat;

  /// Repoint the active chat region (used on session switch). The caller is
  /// responsible for erasing the old content ([eraseChatArea]) and attaching
  /// the new region so it redraws its saved rows.
  void setActiveChat(ScrollingTextRegion region) => _activeChat = region;

  StatusRegion get status => _status;
  InputRegion get input => _input;

  /// The active rendering backend, or null in passthrough mode.
  TerminalBackend? get backend => _backend;

  /// Run a logical retained-mode frame. Nested frames are coalesced by the
  /// backend, so leaf helpers can keep requesting flushes without producing
  /// intermediate terminal frames. Border repairs touched by leaf helpers
  /// during the frame are drained once per row before the backend's
  /// [TerminalBackend.endFrame], so a row written several times in one frame
  /// has its border cells re-emitted at most once.
  T frame<T>(T Function() body) {
    if (passthrough) return body();
    final be = _backend!;
    be.beginFrame();
    _frameDepth++;
    if (_frameDepth == 1) InputLatency.stage(LatencyStage.renderStarted);
    try {
      return body();
    } finally {
      _frameDepth--;
      if (_frameDepth == 0) {
        _drainPendingBorderRepairs();
        // Deferred border repairs each reposition the cursor onto a border
        // cell; re-apply the body's last parked position so it survives as the
        // frame's final positioning command.
        final pr = _parkedRow;
        final pc = _parkedCol;
        if (pr != null && pc != null) {
          be.parkCursor(pr, pc);
        }
        _parkedRow = null;
        _parkedCol = null;
      }
      be.endFrame();
    }
  }

  /// Drain rows touched during the just-closed outermost frame, repairing each
  /// once. The backend frame is still open, so the repair writes batch into it
  /// and flush with the rest of the frame.
  void _drainPendingBorderRepairs() {
    if (_pendingBorderRepairRows.isEmpty) return;
    final rows = _pendingBorderRepairRows.toList()..sort();
    _pendingBorderRepairRows.clear();
    for (final row in rows) {
      _repairBordersForRow(row);
    }
  }

  /// Enqueue a border repair for [row]. Inside a [frame], the repair is
  /// deferred and merged with other rows touched in the same frame (each row
  /// repaired once at [endFrame]). Outside a frame, repair immediately to
  /// preserve flush-on-write semantics.
  void _scheduleBorderRepair(int row) {
    if (_frameDepth > 0) {
      _pendingBorderRepairRows.add(row);
    } else {
      _repairBordersForRow(row);
    }
  }

  /// Public entry for regions that write through their own [BackendSurface]
  /// (Phase 3 overlays/input/chat) and thus bypass [putAtAbsolute]'s built-in
  /// border repair. Schedules repair for [rows] exactly as a same-rectangle
  /// `putAtAbsolute` would have, so split-mode info-box borders stay intact
  /// when an overlay plane covers and then releases them.
  void scheduleBorderRepairs(Iterable<int> rows) {
    for (final r in rows) {
      _scheduleBorderRepair(r);
    }
  }

  /// Enter the alternate screen buffer (xterm `?1049h`) and draw the frame.
  /// Idempotent. No-op in passthrough mode.
  void enterAltScreen() {
    if (passthrough) return;
    if (_inAltScreen) return;
    _inAltScreen = true;
    _backend!.enterAltScreen();
    _backend!.enableBracketedPaste();
    redrawFrame();
    // redrawFrame calls flush(), so alt-screen escape + paste mode + frame
    // are sent together.
  }

  /// Leave the alternate screen buffer. Idempotent.
  void leaveAltScreen() {
    if (passthrough) return;
    if (!_inAltScreen) return;
    _inAltScreen = false;
    _backend!.disableBracketedPaste();
    _backend!.leaveAltScreen();
    _backend!.flush();
  }

  /// Register one animation callback. All active animations are advanced in a
  /// single retained-mode frame, regardless of panel count.
  void registerAnimation(void Function() tick,
      {Duration interval = const Duration(milliseconds: 40)}) {
    _animations.add(tick);
    _animationTimer ??= Timer.periodic(interval, (_) {
      frame(() {
        // Join the chat presentation coordinator: if chat mutations are
        // waiting when the comet ticks, absorb them into this frame so the
        // turn-cue frame also paints chat and the trailing timer is cancelled.
        absorbPendingChat();
        for (final animation in List.of(_animations)) {
          animation();
        }
      });
    });
  }

  void unregisterAnimation(void Function() tick) {
    _animations.remove(tick);
    if (_animations.isEmpty) {
      _animationTimer?.cancel();
      _animationTimer = null;
    }
  }

  // -- Phase 5: adaptive chat presentation scheduling ---------------------
  //
  // Replaces every ScrollingTextRegion's per-region _paintTimer with ONE
  // trailing timer + ONE idle clock for the whole screen. The backend already
  // coalesces any work inside screen.frame() into a single notcurses_render
  // (NotcursesBackend.endFrame flushes only when frameDepth returns to 0), so
  // this layer only decides *when* to enter a frame:
  //
  //   - LEADING EDGE: if no chat frame has been presented within the window,
  //     the first mutation is presented immediately (no 8 ms delay).
  //   - TRAILING EDGE: during sustained writes, mutations accumulate in the
  //     region's pending set and present ONCE at the next window boundary.
  //   - PREEMPTION: an input or animation frame absorbs any pending chat
  //     damage into its own frame and cancels the trailing timer, so it never
  //     fires a redundant second render.
  //
  // Only coalescing backends (notcurses) use the scheduler; the synchronous
  // ANSI path paints immediately and never touches this coordinator.

  /// A chat region reports new mutations. [contentRowsAtWindowStart] is the
  /// region's content-row count at the start of this window — captured only on
  /// the first write of the window so native-scroll gating sees the "buffer was
  /// full when the open window started" baseline.
  void requestChatPresentation(
    ScrollingTextRegion region, {
    required int contentRowsAtWindowStart,
  }) {
    if (passthrough || !(backend?.coalescesPaints ?? false)) {
      // Synchronous path (ANSI): paint immediately, nothing to schedule.
      region.noteContentRowsAtWindowStart(contentRowsAtWindowStart);
      region.flushPendingWrites();
      return;
    }
    final isFirstWriteOfWindow = !_pendingChatRegions.contains(region);
    if (isFirstWriteOfWindow) {
      region.noteContentRowsAtWindowStart(contentRowsAtWindowStart);
    }
    _pendingChatRegions.add(region);
    if (_trailingChatTimer != null) return; // already coalescing; accumulate

    final now = _nanos();
    final idle =
        !_chatEverPainted || now - _lastChatPaintNanos >= _chatWindowNanos;
    if (idle) {
      // Leading edge: present immediately, no timer.
      _flushPendingChat(now);
    } else {
      // Within the window: schedule ONE trailing render at the boundary.
      final remaining = _chatWindowNanos - (now - _lastChatPaintNanos);
      var delay = Duration(microseconds: (remaining / 1000).round());
      if (delay <= Duration.zero) delay = const Duration(microseconds: 1);
      _trailingChatTimer = Timer(delay, () {
        _trailingChatTimer = null;
        _flushPendingChat(_nanos());
      });
    }
  }

  /// Input/animation frame preemption: absorb any pending chat into the frame
  /// that is about to present, and cancel the trailing timer so it never fires
  /// a redundant second render. No-op when nothing is pending.
  void absorbPendingChat() {
    if (_pendingChatRegions.isEmpty) return;
    if (_trailingChatTimer != null) {
      _trailingChatTimer!.cancel();
      _trailingChatTimer = null;
    }
    _flushPendingChat(_nanos());
  }

  /// Present every pending chat region now, inside one coalesced frame.
  void _flushPendingChat(int nowNanos) {
    final regions = _pendingChatRegions.toList();
    _pendingChatRegions.clear();
    if (regions.isEmpty) return;
    _chatEverPainted = true;
    _lastChatPaintNanos = nowNanos;
    frame(() {
      for (final region in regions) {
        region.flushPendingWrites();
      }
    });
  }

  /// Drop all pending chat state (detach / shutdown). Clears the trailing
  /// timer and the pending-region set so no stale paint fires later.
  void resetChatPresentation() {
    _pendingChatRegions.clear();
    if (_trailingChatTimer != null) {
      _trailingChatTimer!.cancel();
      _trailingChatTimer = null;
    }
    _chatEverPainted = false;
    _lastChatPaintNanos = 0;
  }

  /// Release timers owned by the frame coordinator.
  void dispose() {
    _animationTimer?.cancel();
    _animationTimer = null;
    _animations.clear();
    resetChatPresentation();
  }

  /// Resize to a new layout. Repaints the frame and gives each region a
  /// chance to re-render its content within the new bounds.
  void resize(ScreenLayout layout) => frame(() {
        _layout = layout;
        redrawFrame();
        _activeChat.handleResize();
        _status.handleResize();
        _input.handleResize();
        for (final o in _overlays) {
          o.handleResize();
        }
      });

  /// Paint the entire frame: menu box + chat box + info box (when split),
  /// each tinted per the current focus/highlight state.
  void redrawFrame() {
    if (passthrough) return;
    final be = _backend!;
    final w = _layout.width;
    // Clear the menu box content row so stale labels don't linger; the
    // MenuBar repaints its labels on top.
    if (_layout.hasMenuBar) {
      be.eraseCells(_layout.menuBarRow, 1, w - 2);
    }
    _repaintBoxBorders();
    // Park the cursor at the chat region's top-left.
    be.moveCursor(_layout.chat.row, _layout.chat.col);
    be.flush();
  }

  /// Repaint the menu/info box borders with the current focus/highlight
  /// accents. The chat area is no longer a Screen-painted box — each
  /// [ConversationPanel] draws its own chrome — so only the (dormant) menu and
  /// info boxes remain here.
  List<({FrameBox box, int left, int right, int top, int bottom, String title})>
      get _boxSpecs {
    final w = _layout.width;
    return [
      if (_layout.hasMenuBar)
        (
          box: FrameBox.menu,
          left: 0,
          right: w - 1,
          top: _layout.menuTopBorderRow,
          bottom: _layout.menuBottomBorderRow,
          title: '',
        ),
      if (_layout.isSplit && _layout.drawInfoFrame)
        (
          box: FrameBox.info,
          left: _layout.infoLeftCol,
          right: _layout.infoRightCol,
          top: _layout.topBorderRow,
          bottom: _layout.bottomBorderRow,
          title: 'info',
        ),
    ];
  }

  /// Self-contained: saves/restores the cursor and flushes.
  void _repaintBoxBorders() {
    if (passthrough) return;
    final be = _backend!;
    be.saveCursor();
    for (final s in _boxSpecs) {
      _paintBoxBorder(
        be,
        leftCol: s.left,
        rightCol: s.right,
        topRow: s.top,
        bottomRow: s.bottom,
        title: s.title,
        accent: _accentForBox(s.box),
      );
    }
    be.restoreCursor();
    be.flush();
  }

  /// Accent for [box], or null. While a box is highlighted (cycling), only the
  /// yellow preview shows — the focus (cyan) tint is suppressed so the panel
  /// being navigated away from goes plain. Otherwise a focused box is cyan.
  String? _accentForBox(FrameBox box) {
    if (box == _highlightedBox) return theme.border.selection;
    if (_highlightedBox == null && box == _focusedBox) {
      return theme.border.focus;
    }
    return null;
  }

  /// Mark [box] as the focused (input) panel — cyan border. Repaints.
  void focusFrame(FrameBox box) {
    if (_focusedBox == box) return;
    _focusedBox = box;
    _repaintBoxBorders();
  }

  /// Clear the focused panel so no box has a cyan border. Used when a
  /// non-FrameBox focusable (e.g. a spawned panel) takes focus.
  void clearFocusFrame() {
    if (_focusedBox == null) return;
    _focusedBox = null;
    _repaintBoxBorders();
  }

  /// Mark [box] as the cycling highlight (yellow border), or null for none.
  void highlightFrame(FrameBox? box) {
    if (_highlightedBox == box) return;
    _highlightedBox = box;
    _repaintBoxBorders();
  }

  /// Draw the border lines of a single panel box. Interior cells are left
  /// blank — the regions inside fill them. The title separator, corners, and
  /// sides are painted with [accent] (or plain when null).
  void _paintBoxBorder(
    dynamic be, {
    required int leftCol,
    required int rightCol,
    required int topRow,
    required int bottomRow,
    required String title,
    String? accent,
  }) {
    final width = rightCol - leftCol + 1;
    final label = ' $title ';
    final hasTitle = title.isNotEmpty && label.length <= width - 3;

    String paint(String s) => accent == null ? s : colorize(accent, s);

    // Top: ┌─ title ────┐.
    final top = StringBuffer()..write(paint('┌'));
    if (hasTitle) {
      top
        ..write(paint('─'))
        ..write(paint(label))
        ..write(paint('─' * (width - 3 - label.length)));
    } else {
      top.write(paint('─' * (width - 2)));
    }
    top.write(paint('┐'));
    be.moveCursor(topRow, leftCol);
    be.writeText(top.toString());

    // Sides — a single vertical bar at leftCol and rightCol.
    final v = paint('│');
    for (var r = topRow + 1; r < bottomRow; r++) {
      be.moveCursor(r, leftCol);
      be.writeText(v);
      be.moveCursor(r, rightCol);
      be.writeText(v);
    }

    // Bottom: └────────┘.
    final bottom = StringBuffer()
      ..write(paint('└'))
      ..write(paint('─' * (width - 2)))
      ..write(paint('┘'));
    be.moveCursor(bottomRow, leftCol);
    be.writeText(bottom.toString());
  }

  /// Erase the chat region visually (preserving frame) WITHOUT touching any
  /// region's row buffer. Used when swapping the active region on a session
  /// switch — the incoming region redraws its own saved rows via `attach()`.
  void eraseChatArea() {
    final r = _layout.chat;
    final be = _backend!;
    for (var i = 0; i < r.height; i++) {
      be.eraseCells(r.row + i, r.col, r.width);
    }
    be.moveCursor(r.row, r.col);
    be.flush();
  }

  /// Erase the chat region (preserving frame) and reset the active region's
  /// row buffer. Used by `/clear` and Ctrl+L.
  void clearChat() {
    eraseChatArea();
    _activeChat.resetAfterClear();
  }

  /// Park the visible cursor at an absolute terminal position. Called by
  /// regions (mainly [InputRegion]) when they want the user's cursor visible
  /// at a specific spot.
  void parkCursorAt(int row, int col) {
    _parkedRow = row;
    _parkedCol = col;
    _backend!.parkCursor(row, col);
    _backend!.flush();
  }

  /// Create a [BackendSurface] occupying [bounds], for an independent,
  /// z-orderable drawable area. Used by [Panel] to obtain its backing plane.
  ///
  /// In passthrough mode the surface writes content straight to [io] with no
  /// positioning (panels aren't meaningful without a frame, but this keeps the
  /// abstraction total). Otherwise it delegates to the backend.
  BackendSurface createSurface(Rect bounds) {
    if (passthrough) return _PassthroughSurface(io, bounds);
    return _backend!.createSurface(bounds);
  }

  /// Force the backend to re-emit the last presented frame in full,
  /// bypassing damage tracking. Run once after every terminal resize: some
  /// terminals (tmux foremost) scroll or drop alternate-screen content when
  /// the pane shrinks, so the terminal's grid diverges from the backend's
  /// retained frame and damage-only repaints would leave the dropped rows
  /// stale forever. See [TerminalBackend.refresh].
  void refresh() {
    if (passthrough) return;
    _backend!.refresh();
  }

  // -- Region-facing primitives --------------------------------------------

  /// The rightmost absolute column a primitive may write when an optional
  /// [clipRect] is in effect. Null (or an overshooting rect) means the screen
  /// edge — the historical behaviour — so every call below is byte-identical
  /// unless a caller passes a tighter content rect. This is the defensive
  /// clip that keeps a stale-bounds region from writing past its panel even on
  /// the absolute (non-surface) path.
  int _clipRight(Rect? clipRect) {
    if (clipRect == null) return _layout.width;
    return (clipRect.col + clipRect.width).clamp(0, _layout.width);
  }

  /// Write [text] starting at absolute (row, col), clipped to a maximum
  /// visible width of [maxCols] cells.
  ///
  /// Text is treated as a single line (no `\n` allowed). ANSI escapes in
  /// [text] are preserved but don't count toward the column budget. After
  /// writing, the touched border cells on this row are re-emitted so they
  /// can't have been clobbered by erase sequences.
  ///
  /// [moveCursor] = false wraps the call in save/restore so the visible
  /// cursor doesn't move (used for status overlays and frame writes).
  void putAtAbsolute({
    required int row,
    required int col,
    required String text,
    required int maxCols,
    required bool moveCursor,
    Rect? clipRect,
  }) {
    if (row < 0 || row >= _layout.height) return;
    if (col < 0 || col >= _layout.width) return;
    final clipRight = _clipRight(clipRect);
    if (col >= clipRight) return;
    // maxCols already bounds the write; tighten it to the clip rect's right
    // edge when one is in effect. Unchanged when clipRect is null.
    final cols = clipRect == null || maxCols < clipRight - col
        ? maxCols
        : clipRight - col;
    final clipped = _clipToVisibleCols(text, cols);
    final be = _backend!;
    if (!moveCursor) be.saveCursor();
    be.moveCursor(row, col);
    be.eraseCells(row, col, cols);
    be.writeText(clipped);
    if (OpCounters.enabled) OpCounters.instance.gridWrites++;
    _scheduleBorderRepair(row);
    if (!moveCursor) be.restoreCursor();
    be.flush();
  }

  /// Replace only a changed span of a row. [clearCells] cells are erased at
  /// the span origin before [text] is written, allowing callers with retained
  /// row state to avoid rewriting the unchanged prefix and suffix. [clipRect],
  /// when supplied, bounds the span to a content rect so a stale-bounds caller
  /// cannot write past it.
  void patchAtAbsolute({
    required int row,
    required int col,
    required String text,
    required int clearCells,
    Rect? clipRect,
  }) {
    if (row < 0 || row >= _layout.height) return;
    if (col < 0 || col >= _layout.width) return;
    final clipRight = _clipRight(clipRect);
    if (col >= clipRight) return;
    final be = _backend!;
    be.moveCursor(row, col);
    // Partial writes cannot assume the backend's current SGR state: another
    // region may have painted since this row was last touched.
    be.writeText('\x1b[0m');
    final clear = clearCells.clamp(0, clipRight - col);
    if (clear > 0) be.eraseCells(row, col, clear);
    be.moveCursor(row, col);
    be.writeText(_clipToVisibleCols(text, clipRight - col));
    if (OpCounters.enabled) OpCounters.instance.gridWrites++;
    _scheduleBorderRepair(row);
    be.flush();
  }

  /// Replace the span starting at absolute (row, col) with [runs], re-
  /// establishing each run's style from the default baseline. [clearCells] cells
  /// are erased at the origin first so a shorter new span clears the old tail.
  ///
  /// Unlike [patchAtAbsolute] (which writes plain text and can therefore never
  /// carry per-cell SGR), this emits a styled span: a leading reset establishes
  /// the known default baseline, then [renderStyledRuns] emits each changed run
  /// as a self-contained `<reset><sgr…m text>` so no run depends on style a
  /// prior region left active. This is the partial-write primitive the styled
  /// run-span diff (diffStyledRuns) uses on the null-surface path.
  void patchStyledAtAbsolute({
    required int row,
    required int col,
    required List<StyledRun> runs,
    required int clearCells,
    Rect? clipRect,
  }) {
    if (row < 0 || row >= _layout.height) return;
    if (col < 0 || col >= _layout.width) return;
    final clipRight = _clipRight(clipRect);
    if (col >= clipRight) return;
    final be = _backend!;
    be.moveCursor(row, col);
    // Known default baseline before any partial styled write.
    be.writeText('\x1b[0m');
    final clear = clearCells.clamp(0, clipRight - col);
    if (clear > 0) be.eraseCells(row, col, clear);
    be.moveCursor(row, col);
    be.writeText(_clipToVisibleCols(renderStyledRuns(runs), clipRight - col));
    if (OpCounters.enabled) OpCounters.instance.gridWrites++;
    _scheduleBorderRepair(row);
    be.flush();
  }

  /// Erase [n] cells starting at absolute (row, col). Border cells on the
  /// row are re-emitted afterwards.
  void eraseAtAbsolute({
    required int row,
    required int col,
    required int n,
    required bool moveCursor,
    Rect? clipRect,
  }) {
    if (row < 0 || row >= _layout.height) return;
    if (col < 0 || col >= _layout.width) return;
    final clipRight = _clipRight(clipRect);
    if (col >= clipRight) return;
    final be = _backend!;
    if (!moveCursor) be.saveCursor();
    // Clip n to the clip rect's right edge (the screen edge when no clip).
    final clipped = (col + n > clipRight) ? clipRight - col : n;
    if (clipped > 0) {
      be.eraseCells(row, col, clipped);
      if (OpCounters.enabled) OpCounters.instance.erasedCells += clipped;
    }
    _scheduleBorderRepair(row);
    if (!moveCursor) be.restoreCursor();
    be.flush();
  }

  /// Apply ANSI colour to [text] when colour is enabled.
  String colorize(String code, String text) {
    if (passthrough) {
      if (!ansi.useColor) return text;
      return '\x1b[${code}m$text\x1b[0m';
    }
    return _backend!.colorize(code, text);
  }

  /// Swap the active theme at runtime. All subsequent paints (region emit,
  /// frame borders, comet animation) pick up the new values.
  ///
  /// A theme change resolves to different SGR code strings, so we must force a
  /// full repaint of any already-rendered styled rows: drop the active chat
  /// region's retained paint snapshots (otherwise the unchanged-snapshot check
  /// [_emitRow] `previous != text` would suppress rows whose underlying
  /// content is identical but whose SGR codes now differ) and invalidate the
  /// parse cache (its keys embed [gThemeStyleVersion], so bumping it prevents
  /// reuse of runs computed against the prior theme's color mapping).
  void setTheme(Theme t) {
    _theme = t;
    bumpThemeStyleVersion();
    styledRunCache.clear();
    _activeChat.clearPaintSnapshots();
  }

  void registerOverlay(OverlayRegion o) {
    if (!_overlays.contains(o)) _overlays.add(o);
  }

  void unregisterOverlay(OverlayRegion o) {
    _overlays.remove(o);
  }

  // -- Z-order (Phase 3) ----------------------------------------------------
  //
  // Chat regions render onto their own opaque child planes, so anything that
  // must float above chat (the input row, completion picker, dialogs, menus)
  // also needs a plane above chat. These helpers keep the stack ordered:
  //   standard plane < chat planes < input plane < overlay planes
  // Raising a chat plane re-asserts input+overlays on top; showing an overlay
  // raises it above everything. On ANSI surfaces raiseToTop is a no-op, so
  // these are inert there (and the surfaces are emulated anyway).

  /// Register a chat surface. Tracked so [raiseChatSurface] can re-assert the
  /// input/overlay planes above it after focus raises one chat above another.
  void adoptChatSurface(BackendSurface s) {
    _chatSurfaces.add(s);
    if (_activeChatSurface == null) _activeChatSurface = s;
  }

  /// Raise [s] above other chat surfaces, then re-raise the input and overlay
  /// planes so they stay above chat. Called from ConversationPanel.focus().
  void raiseChatSurface(BackendSurface s) {
    _activeChatSurface = s;
    s.raiseToTop();
    _raiseOverlays();
  }

  /// Register the input surface and raise it above chat. Called once when
  /// InputRegion first creates its plane.
  void adoptInputSurface(BackendSurface s) {
    _inputSurface = s;
    s.raiseToTop();
  }

  /// Register an overlay surface (shown) and raise it above everything.
  void adoptOverlaySurface(BackendSurface s) {
    _overlaySurfaces.add(s);
    s.raiseToTop();
  }

  /// Forget a destroyed overlay surface (OverlayRegion.hide destroys its plane).
  void releaseOverlaySurface(BackendSurface s) {
    _overlaySurfaces.remove(s);
  }

  /// Re-raise the input plane, then each visible overlay plane, above the
  /// currently-focused chat plane. Callers that raise a chat plane must run
  /// this so the input row and any open dialog stay visible.
  void _raiseOverlays() {
    _inputSurface?.raiseToTop();
    for (final s in _overlaySurfaces) {
      s.raiseToTop();
    }
  }

  /// Render a decoded image at absolute ([row], [col]), clipped to [maxCols]
  /// cells wide.  [rgba] is a 32-bit-per-pixel RGBA buffer, [width]×[height]
  /// pixels.  Delegates to the backend, which picks pixel-protocol vs
  /// rasterized-block fallback.  ANSI backends draw a dimmed placeholder.
  ///
  /// Off-screen origins are a no-op (mirrors [putAtAbsolute]).
  void renderImageAbsolute({
    required int row,
    required int col,
    required Uint32List rgba,
    required int width,
    required int height,
    required int maxCols,
    BackendSurface? targetSurface,
  }) {
    if (passthrough) return;
    if (row < 0 || row >= _layout.height) return;
    if (col < 0 || col >= _layout.width) return;
    final be = _backend!;
    be.renderImageAbsolute(
      row: row,
      col: col,
      rgba: rgba,
      width: width,
      height: height,
      maxCols: maxCols,
      targetSurface: targetSurface,
    );
    // Flush-on-write, mirroring putAtAbsolute: the ANSI backend batches into
    // an internal buffer that only reaches io on flush, and the notcurses
    // backend's render() is idempotent, so this makes the image visible now.
    be.flush();
  }

  // -- Internal helpers ----------------------------------------------------

  /// Re-emit any border cells on [row] via the backend. Cheap when no
  /// borders live on that row — the layout's [borderCharFor] returns null
  /// for interior cells and the loop degenerates. The chat area's border is
  /// panel-drawn (see [ConversationPanel]) and not repaired here; only the
  /// (dormant) menu/info box borders are.
  void _repairBordersForRow(int row) {
    if (row < 0 || row >= _layout.height) return;
    final be = _backend!;
    final cols = <int>[
      if (_layout.isSplit) _layout.infoLeftCol,
      if (_layout.isSplit) _layout.infoRightCol,
    ];
    for (final col in cols) {
      final ch = _layout.borderCharFor(row, col);
      if (ch != null) {
        final accent = _accentForBorderCol(row, col);
        be.moveCursor(row, col);
        be.writeText(accent == null ? ch : colorize(accent, ch));
        if (OpCounters.enabled) OpCounters.instance.borderRepairs++;
      }
    }
  }

  /// Accent for the border cell at ([row], [col]), or null. Row-aware because
  /// cols 0 and width−1 are shared between the menu box (rows 0–2) and info
  /// (rows 3+). Resolves which box the cell belongs to, then its focus (cyan)
  /// / highlight (yellow) state.
  String? _accentForBorderCol(int row, int col) {
    // Menu box (rows 0–2).
    if (_layout.hasMenuBar &&
        (row == _layout.menuTopBorderRow ||
            row == _layout.menuBarRow ||
            row == _layout.menuBottomBorderRow)) {
      return _accentForBox(FrameBox.menu);
    }
    // Info box.
    if (_layout.isSplit &&
        (col == _layout.infoLeftCol || col == _layout.infoRightCol)) {
      return _accentForBox(FrameBox.info);
    }
    return null;
  }

  String _clipToVisibleCols(String s, int maxCols) =>
      clipToVisibleColumns(s, maxCols);
}

/// Pulled in by [Screen.putAtAbsolute] for word-aware wrapping when the
/// caller wants it. Public so regions that compose multi-row content
/// (chat streaming, input prompt) can wrap before they call put.
List<String> wrapForWidth(String text, int width) => wrapAnsiAware(text, width);

/// [BackendSurface] for passthrough mode (`--prompt` / non-TTY runs). Writes
/// content straight to [Stdio] with no positioning; geometry and z-order are
/// no-ops. Panels aren't meaningful without a frame, but this keeps the
/// abstraction total so [Panel] code paths don't need a passthrough branch.
class _PassthroughSurface implements BackendSurface {
  final Stdio io;
  Rect _bounds;
  _PassthroughSurface(this.io, this._bounds);

  @override
  Rect get bounds => _bounds;

  @override
  void putAt({
    required int relRow,
    required int relCol,
    required String text,
    required int maxCols,
    required bool moveCursor,
  }) {
    if (text.endsWith('\n')) {
      io.write(text);
    } else {
      io.write('$text\n');
    }
  }

  @override
  void eraseAt({
    required int relRow,
    required int relCol,
    required int n,
    required bool moveCursor,
  }) {}

  @override
  void moveTo(int row, int col) {}

  @override
  void resize(int width, int height) {}

  @override
  void raiseToTop() {}

  @override
  void lowerToBottom() {}

  @override
  bool scrollRows(int count) => false; // passthrough has no native scroll.

  @override
  void destroy() {}
}
