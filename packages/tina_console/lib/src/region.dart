import 'dart:async';

import 'package:meta/meta.dart';

import 'backend/backend_surface.dart';
import 'input_latency.dart';
import 'rect.dart';
import 'screen.dart';
import 'styled_text.dart';
import 'term_width.dart';

/// A bounded write surface on the [Screen]. Subclasses cannot, by
/// construction, write outside [bounds] — they go through the screen's
/// clipping primitives.
abstract class Region {
  final Screen screen;
  Region(this.screen);

  Rect get bounds;

  /// Called by [Screen.resize] after the layout changes so subclasses can
  /// re-render their content within the new rectangle. Default: no-op.
  void handleResize() {}
}

/// Streaming, append-only text region. Used for the chat panel.
///
/// Writes wrap at [bounds.width] and advance row-by-row. When new content
/// would land past the bottom of the region, older rows scroll up. Each
/// row is buffered so a scroll can be redrawn without losing what was on
/// screen.
///
/// Methods named after colours emit the ANSI SGR codes (subject to the
/// screen's [AnsiCapable]).
class ScrollingTextRegion extends Region {
  final List<_StyledRow> _rows;
  int _curRow = 0;
  int _curCol = 0;

  /// Owner of the currently-open partial row, if any. Set by a write that
  /// carries a [rowOwner] and ends mid-row (no trailing newline); cleared
  /// when the row completes. While set, any OTHER writer's text starts a
  /// fresh row instead of appending to the partial one — otherwise a
  /// background writer (e.g. the environment ceremony) streaming while an
  /// approval prompt awaits its answer would merge its text onto the
  /// approval's "approve? … › " row (tin-6a2f).
  Object? _openRowOwner;

  /// When true, writes go to [_detachedBuffer] instead of the screen.
  bool _detached = false;
  final StringBuffer _detachedBuffer = StringBuffer();

  /// SGR code (e.g. `30;47`) tagging every row touched while a styled message
  /// block is open. Set by [beginStyle]/[writeStyledLine]; cleared by
  /// [_endLineStyle] (run at the start of any plain write). Null = no bar — the
  /// row renders on the terminal's default background. The style is applied at
  /// emit time in [_emitRow], which pads the row to the full region width so
  /// the background forms a solid bar.
  String? _pendingStyle;
  final Set<int> _pendingPaintRows = {};
  bool _pendingFullPaint = false;
  // Phase 4: coalesced native-scroll count. Each scroll in a coalesced window
  // bumps this instead of touching every (now-shifted) row; the presentation
  // coordinator then issues one BackendSurface.scrollRows and emits only the
  // new bottom rows.
  int _pendingScrollCount = 0;
  // The content-row count at the start of the coalesced window. A native scroll
  // is only valid when the buffer was already full (every usable row carried
  // content) so the bottom-aligned offset is zero — otherwise the model would
  // bottom-align a blank to the top while scrollUp exposes a blank at the
  // bottom, diverging from the ANSI redraw path. Captured by the presentation
  // coordinator at the first write of each window (via [noteContentRows]).
  int _pendingWindowContentRows = 0;

  bool get _coalescePaints => screen.backend?.coalescesPaints ?? false;

  /// Optional fixed bounds. When null (the default) the region tracks
  /// [Screen.layout.chat] live — the primary chat surface. When set, the
  /// region renders into an explicit rectangle (e.g. a spawned-conversation
  /// column slot) and is repositioned via [setBounds]. Either way the row
  /// buffer is reconciled to [bounds] on resize by [handleResize].
  Rect? _boundsOverride;

  /// Number of bottom rows reserved for the shared input line (spawned panels
  /// only). Content never writes there and is bottom-aligned above them, but
  /// the row *buffer* keeps its full [bounds.height] — so toggling the inset
  /// (when a panel gains/loses focus) shifts content visually without dropping
  /// any buffered rows. This is what keeps cycling focus from eating history:
  /// a height change via [setBounds] reconciles the buffer and can drop the
  /// oldest row, but an inset change never touches the buffer length.
  int _bottomInset = 0;

  /// When true, [_redrawAll] leaves the bottom-inset rows alone — the
  /// enclosing panel owns input rendering and repaints those rows itself.
  bool keepBottomInset = false;

  /// Rows that have scrolled up out of the visible window, oldest first — the
  /// scrollback history. The visible window ([_rows]) keeps its fixed height
  /// (so the offset-0 emit/native-scroll/diff paths are byte-identical to the
  /// pre-scrollback behaviour); rows evicted by [_advanceRow]'s scroll land
  /// here so PgUp/PgDn can reach them. Bounded by [_maxHistoryRows].
  final List<_StyledRow> _history = [];

  /// Cap on retained scrollback rows. Past this the oldest history row is
  /// dropped. Large enough for paging back through a long turn, bounded so a
  /// long session can't grow without limit.
  static const int _maxHistoryRows = 2000;

  /// Scrollback offset: 0 = pinned to the tail (newest at the bottom),
  /// increasing values look further back into [_history]. PgUp increases it,
  /// PgDn decreases it; new content arriving while scrolled up does NOT change
  /// it (the view stays put — see [_advanceRow]).
  int _scrollOffset = 0;

  /// Count of content lines that arrived while [_scrollOffset] > 0, for the
  /// "↓ N new" border badge. Reset to 0 when the view returns to the tail.
  int _newWhileScrolled = 0;

  /// Fired (deferred, coalesced) whenever the scrollback offset or the
  /// new-while-scrolled counter changes, so the host/coordinator can refresh
  /// the "↓ N new" badge without polling. Deferred via a microtask so it never
  /// re-enters a write frame mid-stream.
  void Function()? onScrollbackChanged;
  bool _scrollbackNotifyScheduled = false;

  /// Phase 3: the chat region's own opaque child plane. When non-null, chat
  /// emits go plane-relative through [_surface.putAt] instead of absolute
  /// through [Screen.putAtAbsolute]. This is what lets a scroll be one native
  /// [BackendSurface.scrollRows] + one new bottom row (Step 4) instead of an
  /// O(H) full redraw. The plane is sized to [_usableHeight] (excludes the
  /// bottom-inset/input row) so it never covers the input row on the standard
  /// plane. Null on ANSI/passthrough (emulated surfaces have no z-order, so
  /// the absolute path is used unchanged → byte-identical output).
  BackendSurface? _surface;

  /// A surface the region borrows but does not own (the frame-owns-canvas
  /// model): when non-null, [bounds] derives from it and [_ensureSurface]/
  /// [_destroySurface] never create or destroy it — the owning [PanelFrame]
  /// does. Null in the legacy mode where the region owns [_surface].
  BackendSurface? _boundSurface;

  /// The chat surface, for the coordinator/conversation panel to raise on
  /// focus. Null when the region has no plane (ANSI, passthrough, detached).
  BackendSurface? get surface => _surface ?? _boundSurface;

  /// Borrow [s] as this region's canvas, making the owning frame the single
  /// source of geometry: [bounds] then reads from the surface and the region
  /// stops managing its own surface (it neither creates nor destroys the
  /// borrowed one). Pass null to return to the legacy, region-owns-surface
  /// model. Paint snapshots are cleared so the next emit re-renders cleanly
  /// against the new geometry source.
  void bindSurface(BackendSurface? s) {
    _boundSurface = s;
    _surface = s;
    clearPaintSnapshots();
  }

  /// Whether a borrowed (frame-owned) surface is bound.
  bool get hasBoundSurface => _boundSurface != null;

  /// (Re)create the chat surface at the current content rectangle. Idempotent
  /// for a given size: a live surface of the right size is reused. The surface
  /// is sized to [_usableHeight] so the input row (on the standard plane,
  /// below the inset) is never covered.
  void _ensureSurface() {
    if (_detached || screen.passthrough) return;
    // Borrowed (frame-owned) surface: the frame sizes/positions it; just adopt
    // it as our emit target and never resize/move/recreate it.
    if (_boundSurface != null) {
      _surface = _boundSurface;
      return;
    }
    final b = bounds;
    final h = _usableHeight;
    if (h <= 0 || b.width <= 0) return;
    if (_surface != null &&
        _surface!.bounds.height == h &&
        _surface!.bounds.width == b.width &&
        _surface!.bounds.row == b.row &&
        _surface!.bounds.col == b.col) {
      return; // already the right size and position
    }
    if (_surface != null) {
      // Geometry changed: resize (discards content) and move. The caller
      // follows with _redrawAll, which re-emits everything.
      _surface!.resize(b.width, h);
      _surface!.moveTo(b.row, b.col);
      return;
    }
    BackendSurface? s;
    try {
      s = screen.createSurface(Rect(
        row: b.row,
        col: b.col,
        width: b.width,
        height: h,
      ));
    } catch (_) {
      // A backend that can't (or won't) provide a surface for this rect
      // throws — notcurses throws StateError when it can't allocate a plane,
      // and test fakes throw UnimplementedError. Either way the surface is a
      // pure optimization; chat renders correctly via the absolute path
      // (_emitRow falls back when _surface is null).
      s = null;
    }
    if (s == null) return;
    _surface = s;
    screen.adoptChatSurface(s);
  }

  /// Tear down the chat surface (detach/shutdown). Clears paint state so a
  /// later [_ensureSurface] + redraw starts fresh.
  void _destroySurface() {
    // Borrowed (frame-owned) surface: detach from it but never destroy it —
    // the owning PanelFrame controls its lifetime.
    if (_boundSurface != null) {
      _surface = null;
      clearPaintSnapshots();
      return;
    }
    final s = _surface;
    if (s == null) return;
    s.destroy();
    _surface = null;
    clearPaintSnapshots();
  }

  /// Drop every row's retained paint snapshot so the next repaint re-emits
  /// each row from scratch. Called on resize and on theme change (a new theme
  /// resolves to different SGR code strings, so the old snapshots would
  /// otherwise suppress the repaint that applies the new colors).
  void clearPaintSnapshots() {
    for (var i = 0; i < _rows.length; i++) {
      _rows[i].paintedText = null;
      _rows[i].paintedVisualRow = null;
      _rows[i].paintedCol = null;
      _rows[i].paintedWidth = null;
    }
  }

  ScrollingTextRegion(Screen screen, {Rect? bounds})
      : _boundsOverride = bounds,
        _rows = List.generate(
            (bounds ?? screen.layout.chat).height, (_) => _StyledRow(),
            growable: true),
        super(screen);

  @override
  Rect get bounds =>
      _boundSurface?.bounds ?? _boundsOverride ?? screen.layout.chat;

  /// Reposition this region to [r] and reconcile the row buffer to the new
  /// height. Only meaningful for regions created with an explicit bounds
  /// override; the primary chat region ignores this and tracks the layout.
  void setBounds(Rect r) {
    if (_boundsOverride == null) return;
    _boundsOverride = r;
    _reconcileRows();
    // Repaint at the new position immediately when live; a detached region
    // redraws on attach. (The caller is responsible for erasing stale pixels
    // at the old position — typically by clearing the column before layout.)
    if (!_detached) {
      _ensureSurface();
      _redraw();
    }
  }

  /// Give this region an explicit bounds rectangle (a spawned/restored panel
  /// slot) so [setBounds] can reposition it. Without an override the region
  /// tracks [Screen.layout.chat] and ignores [setBounds] — which is exactly the
  /// case for a restored conversation's chat, so the panelize path calls this
  /// before laying out. Reconciles the row buffer to the new height.
  ///
  /// When live (attached), the BackendSurface is resized+moved to the new rect
  /// in place (preserving plane identity, which native scroll depends on) and
  /// the rows are re-emitted. This is what keeps the surface tracking the panel
  /// on a resize/reposition: previously only [setBounds] did this, and [fit]
  /// routed through [setBoundsOverride], so a moved panel left its surface at
  /// the old origin and writes spilled across the border.
  void setBoundsOverride(Rect? rect) {
    final changed = rect != _boundsOverride;
    _boundsOverride = rect;
    if (rect != null) _reconcileRows();
    if (!_detached && rect != null && changed) {
      _ensureSurface();
      _redraw();
    }
  }

  /// The number of bottom rows currently reserved (for the shared input line).
  int get bottomInset => _bottomInset;

  /// Reserve [n] bottom rows (e.g. for the shared input line). Content stays in
  /// the buffer and is merely bottom-aligned above the reserved rows, so this is
  /// non-destructive and reversible — unlike a height change via [setBounds],
  /// which reconciles the buffer and can drop the oldest row. No redraw while
  /// detached (redrawn on attach).
  void setBottomInset(int n) {
    final clamped = n < 0 ? 0 : n;
    if (_bottomInset == clamped) return;
    _bottomInset = clamped;
    if (!_detached) {
      _ensureSurface(); // plane height tracks _usableHeight
      _redraw();
    }
  }

  /// Rows available for content: the full height less the reserved bottom inset.
  int get _usableHeight {
    final h = bounds.height - _bottomInset;
    return h < 0 ? 0 : h;
  }

  /// Public view of [_usableHeight], used by the coordinator to size a PgUp/PgDn
  /// page for [scrollBy].
  int get usableHeight => _usableHeight;

  /// Append [text] as a plain (unstyled) write. Any open styled block is
  /// closed first via [_endLineStyle], so a tool call, notice, or the next
  /// turn's prompt lands on the default background.
  ///
  /// [rowOwner] marks the write as belonging to a logical row that spans
  /// several writes (e.g. an approval prompt awaiting its answer character).
  /// While such a row is open, other writers' text starts a fresh row
  /// instead of appending to it — see [_openRowOwner].
  void write(String text, {Object? rowOwner}) {
    _endLineStyle();
    _writeInternal(text, rowOwner: rowOwner);
  }

  /// Open a styled block. Idempotent — a no-op if one is already open, so
  /// streaming chunks form one styled run. Tags the current row. Used by the
  /// agent-prose streaming path (the caller picks the code); NOT used by
  /// [writeStyledLine], which force-sets instead.
  void beginStyle(String code) {
    _pendingStyle ??= code;
    _rows[_curRow].styleCode ??= _pendingStyle;
  }

  /// Append [text] inside the open block WITHOUT auto-closing (calls
  /// [_writeInternal] directly; style propagates across wraps via [_advanceRow]).
  /// The block is closed by the next plain [write] or by [endStyle]. Owns the
  /// passthrough/no-color/detached fallback internally (mirrors the old
  /// [writeAgent]): when off, writes plain and leaves any open block untouched.
  void appendStyled(String text) {
    if (screen.passthrough || !screen.ansi.useColor || _detached) {
      _writeInternal(text);
      return;
    }
    _writeInternal(text);
  }

  /// Close the open styled block (current [_endLineStyle]).
  void endStyle() => _endLineStyle();

  /// Full-width styled line. Force-set [code] (never idempotent) so the bar
  /// always wins — even over a leaked/stale open style — matching the old
  /// [writeUserLine]. Choreography: [_endLineStyle], force-set styleCode=code,
  /// write the line, clear [_pendingStyle], write the newline (so the next row
  /// isn't tagged). Owns the passthrough/no-color/detached fallback
  /// internally (mirrors the old [writeUserLine]).
  void writeStyledLine(String text, String code) {
    final line =
        text.endsWith('\n') ? text.substring(0, text.length - 1) : text;
    if (screen.passthrough || !screen.ansi.useColor || _detached) {
      _endLineStyle();
      _writeInternal('$line\n');
      return;
    }
    _endLineStyle();
    _pendingStyle = code; // force (not ??=)
    _rows[_curRow].styleCode = code; // force (not ??=)
    _writeInternal(line);
    // Stop tagging before the line-ending newline so the next row isn't styled.
    _pendingStyle = null;
    _writeInternal('\n');
  }

  /// Close any open styled block: stop tagging new rows, and drop the style
  /// from a trailing empty row (left by a final newline) so the next plain
  /// write renders on the default background.
  void _endLineStyle() {
    if (_pendingStyle == null) return;
    _pendingStyle = null;
    if (_rows[_curRow].isEmpty) {
      _rows[_curRow].styleCode = null;
    }
  }

  /// Append [text]. `\n` advances to the next row; other characters wrap
  /// at the region width. ANSI escape sequences pass through but don't
  /// consume column budget.
  void _writeInternal(String text, {Object? rowOwner}) => screen.frame(() {
        if (text.isEmpty) return;
        if (_detached) {
          _detachedBuffer.write(text);
          return;
        }
        if (screen.passthrough) {
          screen.io.write(text);
          return;
        }
        if (bounds.isEmpty) return;
        // A write that begins on a partial row owned by someone else (an
        // approval prompt awaiting its answer) must not append to it — the
        // previous owner's row ends where it is and this write starts a
        // fresh row. The owner's own writes (the answer character) still
        // append, so "approve? … › y" stays on one row.
        if (_openRowOwner != null && _curCol > 0 && rowOwner != _openRowOwner) {
          final touched = <int>{};
          touched.add(_curRow);
          _advanceRow(touched);
        }
        final previousContentRows = _contentRowCount;
        final touched = <int>{};
        var i = 0;
        while (i < text.length) {
          final ch = text[i];
          if (ch == '\n') {
            touched.add(_curRow);
            _advanceRow(touched);
            i++;
            continue;
          }
          if (ch == '\r') {
            _curCol = 0;
            i++;
            continue;
          }
          // ANSI escape — copy verbatim into the current row buffer.
          if (ch == '\x1b' && i + 1 < text.length && text[i + 1] == '[') {
            final end = _findCsiEnd(text, i);
            final esc = text.substring(i, end);
            _appendToRow(esc, isAnsi: true);
            touched.add(_curRow);
            i = end;
            continue;
          }
          // Append a whole plain run up to the next control/escape or wrap point.
          // Streaming model chunks are usually long prose runs; handling them in
          // one substring avoids rebuilding the row once per UTF-16 code unit.
          // The budget is terminal CELLS (wide runes 2, combining 0 — see
          // term_width.dart), not code units: a row whose stored width exceeds
          // bounds.width lays out wider on the real terminal and autowraps past
          // the plane edge onto the next screen row (tin-q4vz). A rune that
          // does not fit the remaining room ends the run and wraps first —
          // what a terminal does with a wide rune in the last column.
          var room = bounds.width - _curCol;
          var end = i;
          var runWidth = 0;
          while (end < text.length) {
            final unit = text.codeUnitAt(end);
            if (unit == 0x0a || unit == 0x0d || unit == 0x1b) break;
            final width = runeWidth(codePointAt(text, end));
            if (width > room) break;
            runWidth += width;
            room -= width;
            end += runeSizeAt(text, end);
          }
          if (end == i) {
            // The next rune (width ≥ 2) doesn't fit the remaining room.
            // Wrap it to the next row rather than letting it overflow the
            // row's final column — a row laid out wider than bounds.width
            // autowraps on the real terminal and clobbers the next screen
            // row's border (tin-q4vz). A region narrower than the rune
            // itself can never fit it; consume it and let the emit-path
            // clip absorb the damage (never splits a surrogate pair).
            if (runeWidth(codePointAt(text, i)) > bounds.width) {
              end += runeSizeAt(text, i);
            } else {
              touched.add(_curRow);
              _advanceRow(touched);
              continue;
            }
          }
          final run = text.substring(i, end);
          _rows[_curRow].append(run);
          _curCol += runWidth;
          touched.add(_curRow);
          if (_curCol >= bounds.width) _advanceRow(touched);
          i = end;
        }
        _flushRows(touched, previousContentRows: previousContentRows);
        // The row is open (partial) iff the last thing written was not a
        // newline. Track its owner so the next write can decide whether it
        // may append.
        if (_curCol > 0) {
          _openRowOwner = rowOwner;
        } else {
          _openRowOwner = null;
        }
      });

  /// Convenience.
  void writeln([String s = '']) => write('$s\n');
  void newline() => write('\n');

  void dim(String s) => write(screen.colorize(screen.theme.chat.dim, s));
  void cyan(String s) => write(screen.colorize(screen.theme.chat.cyan, s));
  void green(String s) => write(screen.colorize(screen.theme.chat.green, s));
  void yellow(String s) => write(screen.colorize(screen.theme.chat.yellow, s));
  void red(String s) => write(screen.colorize(screen.theme.chat.red, s));
  void color(String code, String s) => write(screen.colorize(code, s));

  /// Turns used to be divided by a horizontal `─` rule in the TUI; messages are
  /// now distinguished by their background style (user bar vs agent bar), so
  /// the rule is gone. Passthrough (piped / non-TTY output) still emits a blank
  /// line between turns for readability — there are no background bars there.
  void separator() {
    if (screen.passthrough) write('\n');
  }

  /// Stop writing to the screen. Future [write] calls accumulate in an
  /// internal buffer. Call [attach] to replay them and resume live writes.
  void detach() {
    // Drop any coalesced chat paint the screen is still owed (the per-region
    // _paintTimer is gone — the screen-global coordinator owns timing now).
    screen.resetChatPresentation();
    _pendingPaintRows.clear();
    _pendingFullPaint = false;
    _pendingScrollCount = 0;
    _pendingWindowContentRows = 0;
    _detached = true;
    _destroySurface();
  }

  /// Resume writing to the screen. Re-renders all buffered rows, then
  /// replays any content that accumulated while detached. The region may
  /// have missed resizes while detached, so reconcile the row buffer to the
  /// current bounds before redrawing.
  void attach() {
    _detached = false;
    _reconcileRows();
    _ensureSurface();
    _redraw();
    final buffered = _detachedBuffer.toString();
    _detachedBuffer.clear();
    if (buffered.isNotEmpty) {
      write(buffered);
    }
  }

  /// Whether this region is currently detached from the screen.
  bool get isDetached => _detached;

  /// The number of retained segments on the buffered row at [row]. Visible for
  /// tests so they can assert that a long-lived row stays bounded under
  /// sustained streaming appends (the Phase 2A allocation invariant).
  @visibleForTesting
  int debugSegmentCount(int row) => _rows[row]._segments.length;

  /// Re-emit [row] without changing its content. Visible for tests to assert
  /// the Phase 2B skip: when a row's painted snapshot still matches, this
  /// produces zero backend cell writes.
  @visibleForTesting
  void debugReemitRow(int row) => screen.frame(() => _emitRow(row));

  /// The last string emitted for [row] (the retained painted snapshot), or null
  /// when the row has no live snapshot. Visible for tests to assert invalidation.
  @visibleForTesting
  String? debugPaintedText(int row) => _rows[row].paintedText;

  /// Used by [Screen.clearChat]. Resets the row buffer and write cursor;
  /// the screen has already erased the rows visually.
  void resetAfterClear() {
    for (var i = 0; i < _rows.length; i++) {
      _rows[i] = _StyledRow();
    }
    _history.clear();
    _curRow = 0;
    _curCol = 0;
    _scrollOffset = 0;
    _newWhileScrolled = 0;
    _detachedBuffer.clear();
  }

  @override
  void handleResize() {
    // Reconcile the row buffer even while detached so a background region
    // stays consistent with the layout and renders correctly on attach.
    _reconcileRows();
    if (_detached) return; // will redraw on attach
    _ensureSurface();
    _redraw();
  }

  // -- Scrollback (PgUp / PgDn) -------------------------------------------

  /// True when the view is pinned to the tail (no scrollback offset). While
  /// false the panel is showing older history and incoming content is held
  /// below the window (see [newWhileScrolled]).
  bool get isTailPinned => _scrollOffset == 0;

  /// The number of content lines that arrived while scrolled up — for the
  /// "↓ N new" border badge. Resets to 0 when the view returns to the tail.
  int get newWhileScrolled => _newWhileScrolled;

  /// The current scrollback offset (rows above the tail). 0 = tail-pinned.
  /// Visible for tests.
  @visibleForTesting
  int get debugScrollOffset => _scrollOffset;

  /// Rows of scrollback retained above the visible window. Visible for tests.
  @visibleForTesting
  int get debugHistoryLength => _history.length;

  /// Scroll the view by [deltaRows] lines, where positive scrolls toward the
  /// tail (PgDn) and negative scrolls back into history (PgUp) — matching the
  /// [PanelFrame.onScroll] convention (+1 pageDown, −1 pageUp). Clamped to
  /// `[0, maxOffset]`. Returning to the tail (offset 0) clears the
  /// new-while-scrolled counter.
  void scrollBy(int deltaRows) {
    final maxOffset = _maxScrollOffset();
    final next = (_scrollOffset - deltaRows).clamp(0, maxOffset);
    if (next == _scrollOffset) return;
    _scrollOffset = next;
    if (_scrollOffset == 0) _newWhileScrolled = 0;
    _redraw();
    _notifyScrollbackChanged();
  }

  /// Snap the view back to the tail: offset and counter both reset to 0.
  /// Called by the host on `/clear` and panel clear so a cleared panel starts
  /// at the tail.
  void scrollToTail() {
    if (_scrollOffset == 0 && _newWhileScrolled == 0) return;
    _scrollOffset = 0;
    _newWhileScrolled = 0;
    _redraw();
    _notifyScrollbackChanged();
  }

  /// Maximum scrollback offset reachable with the retained history and the
  /// current window: `history.length + contentRows - usableHeight` (floored 0).
  int _maxScrollOffset() {
    final usable = _usableHeight;
    final total = _history.length + _contentRowCount;
    return total > usable ? total - usable : 0;
  }

  /// Fire [onScrollbackChanged], deferred and coalesced via a microtask so a
  /// notification triggered inside a write frame (new content while scrolled)
  /// never re-enters rendering mid-stream.
  void _notifyScrollbackChanged() {
    final cb = onScrollbackChanged;
    if (cb == null || _scrollbackNotifyScheduled) return;
    _scrollbackNotifyScheduled = true;
    scheduleMicrotask(() {
      _scrollbackNotifyScheduled = false;
      cb();
    });
  }

  // -- Internals ----------------------------------------------------------

  /// Number of buffer rows that carry content (index 0 through this value - 1).
  /// Used to compute the bottom-alignment offset: when fewer rows have content
  /// than the region height, the content is pushed down so it appears at the
  /// bottom of the region (chat grows up, not down).
  int get _contentRowCount {
    for (var i = _rows.length - 1; i >= 0; i--) {
      if (_rows[i].isNotEmpty) return i + 1;
    }
    return 0;
  }

  /// Adjust the row buffer length and clamp the write cursor to the current
  /// [bounds] without emitting anything. Safe to call while detached.
  void _reconcileRows() {
    final h = bounds.height;
    if (_rows.length != h) {
      if (_rows.length > h) {
        // Height shrink. The buffer holds `content` content rows (top-aligned)
        // followed by blanks; the visible window must keep the MOST RECENT
        // content, so the oldest content rows — not the blank tail — are the
        // ones evicted. Evicted rows are newer than anything already in
        // history, so retain them at history's tail (a resize must not eat
        // scrollback); the blanks that no longer fit are dropped outright
        // (retaining them would pollute scrollback with empty lines).
        //
        // The row the write cursor lands on after the clamps below must not
        // already hold content while the cursor sits BETWEEN rows (_curCol ==
        // 0, the streaming steady state right after a newline): filling the
        // buffer with h content rows clamps the cursor onto the last of them,
        // so the next streamed line appends to it and the two render as one
        // row, persistently (tin-m2vq). A cursor mid-row (_curCol > 0)
        // legitimately shares the content row it is writing into, so it may
        // keep one more.
        final content = _contentRowCount;
        var cursorRow = _curRow;
        if (cursorRow >= h) cursorRow = h - 1;
        final usableAfterShrink = h - _bottomInset;
        if (usableAfterShrink > 0 && cursorRow >= usableAfterShrink) {
          cursorRow = usableAfterShrink - 1;
        }
        var room = _curCol == 0 ? cursorRow : cursorRow + 1;
        if (room < 0) room = 0;
        final keepContent = content > room ? room : content;
        final dropContent = content - keepContent;
        for (var i = 0; i < dropContent; i++) {
          _retainRow(_rows[i]);
        }
        final keepBlanks = h - keepContent;
        final kept = <_StyledRow>[
          ..._rows.sublist(dropContent, content),
          ..._rows.sublist(_rows.length - keepBlanks),
        ];
        _rows
          ..clear()
          ..addAll(kept);
      } else {
        _rows.addAll(List.generate(h - _rows.length, (_) => _StyledRow()));
      }
    }
    if (_curRow >= h) _curRow = h - 1;
    final usable = _usableHeight;
    if (usable > 0 && _curRow >= usable) _curRow = usable - 1;
    if (_curCol > bounds.width) _curCol = bounds.width;
  }

  void _appendToRow(String s, {required bool isAnsi}) {
    if (_curRow >= _usableHeight) {
      // Shouldn't happen because _advanceRow scrolls. Guard.
      _curRow = _usableHeight - 1;
    }
    _rows[_curRow].append(s);
    if (!isAnsi) _curCol += plainWidth(s);
  }

  void _advanceRow(Set<int> touched) {
    if (_curRow + 1 < _usableHeight) {
      _curRow++;
      _curCol = 0;
      // A styled block stays open across wraps: tag the new row too.
      if (_pendingStyle != null) _rows[_curRow].styleCode ??= _pendingStyle;
      return;
    }
    // Scroll: evict the oldest visible row into scrollback history (bounded),
    // then append a fresh blank at the bottom for the incoming content.
    if (_scrollOffset > 0) {
      // Scrolled up: the new line lands at the tail, below the visible window.
      // Stay put — bump the offset by one so the window stays anchored to the
      // same content (offset is measured from the tail, which just moved down),
      // and count it for the "↓ N new" badge. No visible-window repaint.
      _retainRow(_rows.removeAt(0));
      _rows.add(_StyledRow());
      _curCol = 0;
      if (_pendingStyle != null) _rows[_curRow].styleCode ??= _pendingStyle;
      _scrollOffset++;
      _newWhileScrolled++;
      _notifyScrollbackChanged();
      return;
    }
    _retainRow(_rows.removeAt(0));
    _rows.add(_StyledRow());
    _curCol = 0;
    // _curRow still points at the last (now-blank) row after the scroll.
    if (_pendingStyle != null) _rows[_curRow].styleCode ??= _pendingStyle;
    if (_coalescePaints) {
      // Track the scroll for the coalesced fast path; the new bottom row is
      // emitted later (it has no painted snapshot, so _emitRow full-writes it).
      _pendingScrollCount++;
    } else {
      for (var r = 0; r < _usableHeight; r++) {
        touched.add(r);
      }
    }
  }

  /// Push [dropped] onto the scrollback history, dropping the oldest entry
  /// past the cap. Called when a row scrolls out of the visible window.
  void _retainRow(_StyledRow dropped) {
    _history.add(dropped);
    if (_history.length > _maxHistoryRows) {
      _history.removeRange(0, _history.length - _maxHistoryRows);
    }
  }

  void _flushRows(Set<int> touched, {required int previousContentRows}) {
    if (_scrollOffset > 0) {
      // Scrolled up: the write appended below the visible window (see
      // [_advanceRow]) and bumped the new-while-scrolled counter. Stay put —
      // drop the pending visible-window repaint so the view doesn't reflow.
      _pendingPaintRows.clear();
      _pendingFullPaint = false;
      _pendingScrollCount = 0;
      return;
    }
    final redrawAll = _contentRowCount != previousContentRows;
    if (_coalescePaints) {
      // Phase 5: hand off to the screen-global presentation coordinator,
      // which decides leading-edge (immediate) vs trailing-edge (one timer)
      // presentation and gates the native scroll on the window-start baseline.
      _pendingFullPaint |= redrawAll;
      if (!redrawAll) _pendingPaintRows.addAll(touched);
      screen.requestChatPresentation(
        this,
        contentRowsAtWindowStart: previousContentRows,
      );
      return;
    }
    if (redrawAll) {
      // The bottom-alignment offset changed (content grew into a new row, or
      // scrolling added a blank at the end). Every visible row shifted, so
      // redraw all of them — partial updates would leave stale content at
      // the old positions.
      _redrawAll();
      return;
    }
    for (final r in touched) {
      _emitRow(r);
    }
  }

  /// Record the content-row count at the start of a coalescing window. Called
  /// by the presentation coordinator exactly once per window — on the first
  /// write after a (leading or trailing) presentation — so the native-scroll
  /// gate sees the "buffer was full when the window opened" baseline.
  void noteContentRowsAtWindowStart(int contentRows) {
    _pendingWindowContentRows = contentRows;
  }

  /// Emit the mutations accumulated since the last presentation. The
  /// presentation coordinator owns framing (it wraps the notcurses path in one
  /// coalesced screen.frame and paints the ANSI path synchronously), so this
  /// must NOT open its own frame — it just runs the retained fast path or falls
  /// back to a full/row redraw. No-op when detached (writes replay on attach).
  void flushPendingWrites() {
    if (_detached) return;
    if (_scrollOffset > 0) {
      // A presentation queued before the user scrolled up is now for content
      // below the visible window — drop it. The view is frozen on scrollback;
      // the counter was bumped in _advanceRow.
      _pendingFullPaint = false;
      _pendingPaintRows.clear();
      _pendingScrollCount = 0;
      _pendingWindowContentRows = 0;
      return;
    }
    if (OpCounters.enabled) OpCounters.instance.chatRowsEmitted++;
    final scrollCount = _pendingScrollCount;
    final windowWasFull = _pendingWindowContentRows == _usableHeight;
    final full = _pendingFullPaint;
    final rows = Set<int>.of(_pendingPaintRows);
    _pendingFullPaint = false;
    _pendingPaintRows.clear();
    _pendingScrollCount = 0;
    _pendingWindowContentRows = 0;
    final s = _surface;
    // Phase 4: native-scroll fast path. Valid only when (a) the buffer was full
    // when the open window started (offset 0, so the bottom-aligned visualRow
    // matches the plane row), (b) it's still full now, and (c) the window held
    // no full-paint trigger (only scrolls/appends). One scrollRows(N) shifts
    // every retained plane row up by N; the model objects shifted with
    // _advanceRow's removeAt/add, carrying their painted snapshots —
    // _shiftSnapshots just re-anchors paintedVisualRow. We then re-emit every
    // row; the retained rows skip via the diff (their shifted snapshot still
    // matches), and only the rows that received new content this window
    // (including windows with more appends than scrolls) do backend work —
    // independent of terminal height.
    final canScrollNative = scrollCount > 0 &&
        s != null &&
        windowWasFull &&
        _contentRowCount == _usableHeight &&
        full == false;
    if (canScrollNative && s.scrollRows(scrollCount)) {
      _shiftSnapshots(scrollCount);
      for (var r = 0; r < _usableHeight; r++) {
        _emitRow(r);
      }
      return;
    }
    // Either no native scroll possible, or the surface declined (ANSI-style
    // fallback) — revert to the existing full/row path, which is correct for
    // every non-full window.
    if (full) {
      _redrawAll();
    } else {
      for (final row in rows) {
        _emitRow(row);
      }
    }
  }

  /// After a native scrollRows(count): the row objects already shifted in the
  /// model (_advanceRow's removeAt(0)/add), so the only snapshot field that is
  /// stale is paintedVisualRow — it must decrease by [count] since the same
  /// content now sits count rows higher on the plane. Snapshot color/width/col
  /// traveled with the row object, so they're still correct. The newly-exposed
  /// bottom [count] rows have no snapshot (more precisely: the object formerly
  // at row [count] is now row 0; the bottom rows are blanks the model hasn't
  /// written yet), so null them to force a full emit on the next paint.
  void _shiftSnapshots(int count) {
    final usable = _usableHeight;
    if (count <= 0 || count >= usable) return;
    for (var r = 0; r < usable - count; r++) {
      final v = _rows[r].paintedVisualRow;
      if (v != null) _rows[r].paintedVisualRow = v - count;
    }
    for (var r = usable - count; r < usable; r++) {
      _rows[r].paintedText = null;
      _rows[r].paintedVisualRow = null;
      _rows[r].paintedCol = null;
      _rows[r].paintedWidth = null;
    }
  }

  /// Repaint the whole region: the scrollback view when scrolled up, the
  /// normal tail view otherwise. Used by every geometry/resize/attach path so
  /// a panel that is scrolled up stays on scrollback through a resize.
  void _redraw() {
    if (_scrollOffset > 0) {
      _redrawScrollback();
    } else {
      _redrawAll();
    }
  }

  /// Full repaint of the frozen scrollback view: assembles a `usable`-row
  /// window out of `_history` (older) followed by the content rows of `_rows`
  /// (newer), offset back from the tail by [_scrollOffset]. Used only while
  /// scrolled up — at offset 0 the normal [_redrawAll] path applies and is
  /// byte-identical to the pre-scrollback behaviour. Scrollback redraws are
  /// infrequent (only on PgUp/PgDn/resize-while-scrolled), so each row is a
  /// full write with no snapshot diffing.
  void _redrawScrollback() => screen.frame(() {
        _ensureSurface();
        clearPaintSnapshots();
        final usable = _usableHeight;
        final total = _history.length + _contentRowCount;
        final maxOffset = total > usable ? total - usable : 0;
        if (_scrollOffset > maxOffset) _scrollOffset = maxOffset;
        // Combined-list index of the topmost visible line (oldest in window).
        final top = total - usable - _scrollOffset;
        final s = _surface;
        for (var v = 0; v < usable; v++) {
          final idx = top + v;
          if (idx < 0 || idx >= total) {
            // Blank visual row (content shorter than the window at this offset).
            if (s != null) {
              s.eraseAt(
                  relRow: v, relCol: 0, n: bounds.width, moveCursor: false);
            } else {
              screen.eraseAtAbsolute(
                row: bounds.row + v,
                col: bounds.col,
                n: bounds.width,
                moveCursor: false,
                clipRect: bounds,
              );
            }
            continue;
          }
          final row = idx < _history.length
              ? _history[idx]
              : _rows[idx - _history.length];
          final text = _renderRowText(row);
          if (s != null) {
            s.putAt(
              relRow: v,
              relCol: 0,
              text: text,
              maxCols: bounds.width,
              moveCursor: false,
            );
          } else {
            screen.putAtAbsolute(
              row: bounds.row + v,
              col: bounds.col,
              text: text,
              maxCols: bounds.width,
              moveCursor: false,
              clipRect: bounds,
            );
          }
        }
        // Clear the reserved bottom-inset row(s) — same as _redrawAll.
        if (!keepBottomInset) {
          for (var r = usable; r < bounds.height; r++) {
            screen.eraseAtAbsolute(
              row: bounds.row + r,
              col: bounds.col,
              n: bounds.width,
              moveCursor: false,
              clipRect: bounds,
            );
          }
        }
      });

  /// Fully render a row's text with its SGR style and background padding, the
  /// same way [_emitRow] does. Used by the scrollback redraw (a full repaint
  /// of a frozen view, so no snapshot diffing).
  String _renderRowText(_StyledRow row) {
    var text = row.text;
    final style = row.styleCode;
    if (style != null && !screen.passthrough && screen.ansi.useColor) {
      text = _stripLeadingCsi(text);
      if (_hasBackground(style)) {
        // Pad one column SHORT of the region width: a row that exactly fills
        // the backend's grid makes the rasterizer carry the next emit into
        // place via the terminal's autowrap instead of an explicit address,
        // and any terminal whose width table disagrees then displaces that
        // un-addressed run onto the next screen row — blanking the panel
        // border (tin-q4vz). One short column costs a sliver of bar
        // background at the right edge.
        final pad = bounds.width - 1 - _visibleLen(text);
        final padSpaces = pad > 0 ? ' ' * pad : '';
        text = '\x1b[${style}m$text$padSpaces\x1b[0m';
      } else {
        text = '\x1b[${style}m$text\x1b[0m';
      }
    }
    return text;
  }

  void _redrawAll() => screen.frame(() {
        _ensureSurface();
        final usable = _usableHeight;
        // A full redraw re-emits every row, so drop all painted snapshots —
        // otherwise the diff in _emitRow would skip rows whose content didn't
        // change even though their visual position (or the erase above) did.
        for (var i = 0; i < _rows.length; i++) {
          _rows[i].paintedText = null;
        }
        // Clear the top rows that are now empty (stale content from a previous,
        // smaller offset — e.g. after scrolling shifted content down). On the
        // plane these rows belong to the surface; otherwise the standard plane.
        final offset = usable - _contentRowCount;
        final s = _surface;
        for (var r = 0; r < offset; r++) {
          if (s != null) {
            s.eraseAt(relRow: r, relCol: 0, n: bounds.width, moveCursor: false);
          } else {
            screen.eraseAtAbsolute(
              row: bounds.row + r,
              col: bounds.col,
              n: bounds.width,
              moveCursor: false,
              clipRect: bounds,
            );
          }
        }
        for (var r = 0; r < _rows.length; r++) {
          _emitRow(r);
        }
        // Clear the reserved bottom-inset row(s) so the shared input line (or
        // nothing, when not reserved) sits on a blank row, never over content.
        // Skip when the enclosing panel owns input rendering (per-panel inputs).
        // These rows are below the chat plane (sized to _usableHeight), so they
        // always erase on the standard plane.
        if (!keepBottomInset) {
          for (var r = usable; r < bounds.height; r++) {
            screen.eraseAtAbsolute(
              row: bounds.row + r,
              col: bounds.col,
              n: bounds.width,
              moveCursor: false,
              clipRect: bounds,
            );
          }
        }
      });

  /// Emit [relRow] to the screen, offset downward so the chat history is
  /// bottom-aligned within the usable (non-reserved) area: when fewer rows
  /// carry content than the usable height, the content sits just above the
  /// reserved bottom rows. Once the buffer fills and scrolling begins, the
  /// offset drops to zero.
  void _emitRow(int relRow) {
    if (relRow < 0 || relRow >= bounds.height) return;
    final usable = _usableHeight;
    final visualRow = relRow + (usable - _contentRowCount);
    if (visualRow < 0 || visualRow >= usable) return;
    final row = _rows[relRow];
    var text = row.text;
    final style = row.styleCode;
    // Styled rows get their SGR applied at emit time. If the style includes a
    // background, the row is padded (one column short of the full region
    // width — see [_renderRowText]) with spaces under the same SGR so the
    // background forms a solid bar edge to edge. Rows with only a foreground
    // style (agent prose) are left unpadded so they sit on the terminal's
    // default background. putAtAbsolute erases the row first; the pad spaces,
    // when present, re-paint those erased cells.
    if (style != null && !screen.passthrough && screen.ansi.useColor) {
      // Bar content is plain, so any leading CSI here is spurious — typically a
      // closing `\x1b[0m` leaked from a prior colorized write whose text ended
      // in "\n" (e.g. the dim startup banner, a red error). Left in place it
      // would cancel this row's bar SGR before the text, dropping the bar.
      text = _stripLeadingCsi(text);
      if (_hasBackground(style)) {
        final pad = bounds.width - 1 - _visibleLen(text);
        final padSpaces = pad > 0 ? ' ' * pad : '';
        text = '\x1b[${style}m$text$padSpaces\x1b[0m';
      } else {
        text = '\x1b[${style}m$text\x1b[0m';
      }
    }
    final visualRowAbs = bounds.row + visualRow;
    final col = bounds.col;
    final w = bounds.width;

    // Phase 3: when a chat child plane is present, emit plane-relative. The
    // snapshot stores the relative visualRow so the geometry check is
    // consistent within the plane (and so a native scroll in Step 4 can shift
    // snapshots by decrementing paintedVisualRow). Historically the surface
    // path always full-rewrote the row (it has no patchAt) — fine while styled
    // rows were undiffable. Phase 4 follow-on: a styled row (inline SGR) whose
    // tail changed now partial-patches only the changed span, re-establishing
    // each run's style from a clean baseline. Plain prose still full-rewrites.
    final s = _surface;
    if (s != null) {
      final sameGeometry = row.paintedVisualRow == visualRow &&
          row.paintedCol == col &&
          row.paintedWidth == w;
      final previous = sameGeometry ? row.paintedText : null;
      if (previous != text) {
        // Styled partial-patch: parse + diff, then re-emit only the changed
        // tail via a plane-relative putAt at the span offset. The surface
        // putAt first resets to the default baseline and erases maxCols cells
        // there, so the self-contained rendered span renders correctly.
        if (previous != null && text.contains('\x1b')) {
          final prevRuns = styledRunCache.get(previous);
          final newRuns = styledRunCache.get(text);
          final span = prevRuns != null && newRuns != null
              ? diffStyledRuns(prevRuns, newRuns)
              : null;
          if (span != null && span.colOffset > 0) {
            // Clear exactly the old tail (the span the diff replaced) — the
            // same bounded erase patchStyledAtAbsolute applies on the
            // standard-plane path. Run text is plain (SGR lives in the
            // establish calls), so plainWidth is the cell count.
            var oldTailWidth = 0;
            for (var i = span.startIndex; i < prevRuns!.length; i++) {
              oldTailWidth += plainWidth(prevRuns[i].text);
            }
            s.putAt(
              relRow: visualRow,
              relCol: span.colOffset,
              text: renderStyledRuns(span.runs),
              maxCols: w - span.colOffset,
              moveCursor: false,
              clearCells: oldTailWidth,
            );
            row.paintedText = text;
            row.paintedVisualRow = visualRow;
            row.paintedCol = col;
            row.paintedWidth = w;
            return;
          }
          // No common prefix (or parse failed) — fall through to full rewrite.
        }
        // clearCells = the previous painted extent (styled text INCLUDING any
        // background pad — _visibleLen skips the CSI) so the surface erases
        // only the stale tail instead of the full budget (tin-p8k2). Null
        // when there is no same-geometry snapshot: unknown extent, full erase.
        s.putAt(
          relRow: visualRow,
          relCol: 0,
          text: text,
          maxCols: w,
          moveCursor: false,
          clearCells:
              previous != null ? _visibleLen(previous).clamp(0, w) : null,
        );
        row.paintedText = text;
        row.paintedVisualRow = visualRow;
        row.paintedCol = col;
        row.paintedWidth = w;
      }
      return;
    }

    // Phase 2B: diff against the retained snapshot. Skip entirely if the row
    // hasn't changed and still sits at the same geometry; otherwise patch only
    // the changed span. Plain prose patches the changed suffix (a partial write
    // must never split an SGR sequence, so styled rows used to full-rewrite).
    // Phase 4 follow-on: styled rows are now diffable too — parse both rows into
    // runs and re-emit only the changed tail via patchStyledAtAbsolute, which
    // re-establishes each run's style from a known default baseline. The win
    // lands on any row whose prefix is unchanged but whose tail changed (busy
    // comet sweep, progress bar fill, multi-run agent prose).
    final sameGeometry = row.paintedVisualRow == visualRowAbs &&
        row.paintedCol == col &&
        row.paintedWidth == w;
    final previous = sameGeometry ? row.paintedText : null;
    if (previous != text) {
      // Styled diff path: both rows carry inline ANSI. Parse + diff, then
      // re-emit only the changed tail span. Falls back to a full rewrite when
      // parsing is unavailable or there's no common prefix (span starts at 0).
      if (previous != null &&
          text.contains('\x1b') &&
          previous.contains('\x1b')) {
        final oldRuns = styledRunCache.get(previous);
        final newRuns = styledRunCache.get(text);
        final span = oldRuns != null && newRuns != null
            ? diffStyledRuns(oldRuns, newRuns)
            : null;
        if (span != null && span.colOffset > 0) {
          // Changed tail only — clear the old tail width and re-emit the span.
          var oldTailWidth = 0;
          for (var i = span.startIndex; i < oldRuns!.length; i++) {
            oldTailWidth += plainWidth(oldRuns[i].text);
          }
          screen.patchStyledAtAbsolute(
            row: visualRowAbs,
            col: col + span.colOffset,
            runs: span.runs,
            clearCells: oldTailWidth,
            clipRect: bounds,
          );
          row.paintedText = text;
          row.paintedVisualRow = visualRowAbs;
          row.paintedCol = col;
          row.paintedWidth = w;
          return;
        }
        // No common prefix (or parse failed) — fall through to full rewrite.
      }

      // Plain-prose patch path: canPatch only when the diff is safe in the
      // code-unit domain — no inline ANSI (a partial write must never split an
      // SGR sequence) and no unpaired surrogates (a lone surrogate makes
      // _displayWidth/_commonSafePrefix miscount cells — e.g. a surrogate pair
      // split across two writes would leave a stale high surrogate painted and
      // write only the low half). Styled rows with no common prefix also land
      // here via the fall-through above.
      final canPatch = previous != null &&
          !text.contains('\x1b') &&
          !previous.contains('\x1b') &&
          _hasNoUnpairedSurrogates(text) &&
          _hasNoUnpairedSurrogates(previous);
      if (!canPatch) {
        screen.putAtAbsolute(
          row: visualRowAbs,
          col: col,
          text: text,
          maxCols: w,
          moveCursor: true,
          clipRect: bounds,
        );
      } else {
        final prefix = _commonSafePrefix(previous, text);
        screen.patchAtAbsolute(
          row: visualRowAbs,
          col: col + _displayWidth(text.substring(0, prefix)),
          text: text.substring(prefix),
          clearCells: _displayWidth(previous.substring(prefix)),
          clipRect: bounds,
        );
      }
      row.paintedText = text;
      row.paintedVisualRow = visualRowAbs;
      row.paintedCol = col;
      row.paintedWidth = w;
    }
  }

  /// True when [style] sets a background color, so [_emitRow] should pad the
  /// row to the full region width for a solid bar.
  bool _hasBackground(String style) {
    for (final code in style.split(';')) {
      final n = int.tryParse(code);
      if (n == null) continue;
      // Explicit background codes (40–49, 100–107, 48 for extended truecolor)
      // or reverse video (7) which swaps fg/bg and effectively paints a bar
      // across the terminal's default background color.
      if ((n >= 40 && n <= 49) || (n >= 100 && n <= 107) || n == 48 || n == 7) {
        return true;
      }
    }
    return false;
  }

  /// Visible (printable) column width of [s], skipping any embedded CSI
  /// escape sequences, in terminal cells (see term_width.dart). Used to size
  /// the background pad.
  int _visibleLen(String s) {
    var n = 0;
    var i = 0;
    while (i < s.length) {
      if (s[i] == '\x1b' && i + 1 < s.length && s[i + 1] == '[') {
        i = _findCsiEnd(s, i); // lands just past the CSI
        continue;
      }
      n += runeWidth(codePointAt(s, i));
      i += runeSizeAt(s, i);
    }
    return n;
  }

  /// Drop any leading CSI escape sequences from [s]. Used on styled (bar) rows
  /// to remove a leaked closing reset before the bar SGR is applied.
  String _stripLeadingCsi(String s) {
    var i = 0;
    while (
        i < s.length && s[i] == '\x1b' && i + 1 < s.length && s[i + 1] == '[') {
      i = _findCsiEnd(s, i);
    }
    return s.substring(i);
  }

  int _findCsiEnd(String s, int start) {
    var i = start + 2; // skip ESC [
    while (i < s.length) {
      final c = s.codeUnitAt(i);
      if (c >= 0x40 && c <= 0x7E) return i + 1;
      i++;
    }
    return s.length;
  }
}

/// Visible (printable) column width of [s], skipping any embedded CSI escape
/// sequences, in terminal cells (see term_width.dart). Shared by
/// [InputRegion.render] and [ScrollingTextRegion._emitRow] so the input row
/// and chat rows size patches identically.
int _displayWidth(String s) {
  var w = 0;
  var i = 0;
  while (i < s.length) {
    if (s[i] == '\x1b' && i + 1 < s.length && s[i + 1] == '[') {
      i += 2;
      while (i < s.length) {
        final c = s.codeUnitAt(i);
        i++;
        if (c >= 0x40 && c <= 0x7E) break;
      }
      continue;
    }
    w += runeWidth(codePointAt(s, i));
    i += runeSizeAt(s, i);
  }
  return w;
}

/// The longest common code-unit prefix of [a] and [b] that is safe to skip when
/// patching a row: the boundary is backed up if it would split a surrogate
/// pair. Used by [InputRegion.render] and [ScrollingTextRegion._emitRow].
int _commonSafePrefix(String a, String b) {
  final limit = a.length < b.length ? a.length : b.length;
  var i = 0;
  while (i < limit && a.codeUnitAt(i) == b.codeUnitAt(i)) {
    i++;
  }
  if (i > 0 && i < a.length && _isLowSurrogate(a.codeUnitAt(i))) i--;
  return i;
}

bool _isLowSurrogate(int unit) => unit >= 0xdc00 && unit <= 0xdfff;

/// True when [s] contains no unpaired surrogates. A lone surrogate makes the
/// code-unit-based diff in [_emitRow] unsafe (cell counts diverge from code-unit
/// counts), so such rows fall back to a full rewrite. A properly-paired
/// surrogate (e.g. an emoji written as one unit) passes and may patch.
bool _hasNoUnpairedSurrogates(String s) {
  for (var i = 0; i < s.length; i++) {
    final u = s.codeUnitAt(i);
    final high = u >= 0xd800 && u <= 0xdbff;
    final low = u >= 0xdc00 && u <= 0xdfff;
    if (high && (i + 1 >= s.length || !_isLowSurrogate(s.codeUnitAt(i + 1)))) {
      return false;
    }
    if (low && (i == 0 || !_isHighSurrogate(s.codeUnitAt(i - 1)))) {
      return false;
    }
  }
  return true;
}

bool _isHighSurrogate(int unit) => unit >= 0xd800 && unit <= 0xdbff;

/// One buffered chat row: its [text] plus an optional SGR [styleCode] that,
/// when set, [_emitRow] applies to the text. Rows with a background style are
/// padded to the full width so the background paints as a solid bar; rows with
/// only a foreground style are left unpadded. Mutable so append/scroll can edit
/// in place.
///
/// Storage is append-only segments with a cached flattened value, so [append]
/// is O(1) and [text] materializes the whole row at most once per read instead
/// of rebuilding it on every streamed chunk. The segment list is compacted past
/// [segmentCompactThreshold] so a long-lived row can't retain thousands of tiny
/// strings. Segment lists are released when the row is replaced wholesale
/// (clear/scroll/resize), so no explicit teardown is needed.
class _StyledRow {
  /// Once the segment count exceeds this, the segments are joined back into a
  /// single string to bound retained objects under sustained streaming.
  static const int segmentCompactThreshold = 64;

  final List<String> _segments = [];
  String? _flattened;
  String? styleCode;

  /// Retained painted-row snapshot (Phase 2B): the last string emitted to the
  /// terminal for this row (post-SGR, post-padding), plus the absolute geometry
  /// at emit time. When [paintedText] matches the next emit and the geometry is
  /// unchanged, [_emitRow] skips the row entirely; when only a suffix changed
  /// (and neither string carries inline ANSI), it patches the changed span via
  /// [Screen.patchAtAbsolute]. Null forces a full emit. Cleared on
  /// clear/scroll/resize because those replace the whole [_StyledRow].
  String? paintedText;
  int? paintedVisualRow;
  int? paintedCol;
  int? paintedWidth;

  /// Append [value] as a new segment. Empty strings are skipped so [isEmpty]
  /// stays equivalent to `.text.isEmpty`. The flattened cache is invalidated;
  /// the segment list is compacted if it has grown past the threshold.
  void append(String value) {
    if (value.isEmpty) return;
    _segments.add(value);
    _flattened = null;
    if (_segments.length > segmentCompactThreshold) _compact();
  }

  /// The whole row as a single string, materialized lazily and cached. Joining
  /// the segments yields the identical UTF-16 code-unit sequence the old
  /// `text += run` accumulation produced, just deferred.
  String get text => _flattened ??= _segments.join();

  /// True when the row carries no content. Scans segments directly (O(1) for a
  /// row whose first segment is non-empty) rather than materializing [text]
  /// just to test emptiness — important because [_contentRowCount] scans every
  /// row on every paint.
  bool get isEmpty {
    for (final s in _segments) {
      if (s.isNotEmpty) return false;
    }
    return true;
  }

  bool get isNotEmpty => !isEmpty;

  /// Collapse the segment list into a single segment holding the joined text.
  /// The flattened cache is kept valid so the next [text] read is free.
  void _compact() {
    final joined = _segments.join();
    _segments
      ..clear()
      ..add(joined);
    _flattened = joined;
  }
}

/// Random-access region for transient overlays (spinner, progress
/// counter). One [writeAt] per relative row; writes are save/restore so the
/// visible cursor (parked by [InputRegion]) doesn't jump.
class StatusRegion extends Region {
  StatusRegion(super.screen);

  @override
  Rect get bounds => screen.layout.status;

  /// Write [text] at row [relRow] (0-indexed within the region). Erases
  /// the row first; clipped to bounds.
  void writeAt(int relRow, String text) {
    if (screen.passthrough) return;
    if (bounds.isEmpty) return;
    if (relRow < 0 || relRow >= bounds.height) return;
    screen.putAtAbsolute(
      row: bounds.row + relRow,
      col: bounds.col,
      text: text,
      maxCols: bounds.width,
      moveCursor: false,
    );
  }

  /// Erase the content of relative row [relRow]. Borders are restored.
  void clearAt(int relRow) {
    if (screen.passthrough) return;
    if (bounds.isEmpty) return;
    if (relRow < 0 || relRow >= bounds.height) return;
    screen.eraseAtAbsolute(
      row: bounds.row + relRow,
      col: bounds.col,
      n: bounds.width,
      moveCursor: false,
    );
  }

  /// Erase every row of the region.
  void clear() {
    if (bounds.isEmpty) return;
    for (var r = 0; r < bounds.height; r++) {
      clearAt(r);
    }
  }
}

/// The editable prompt row. Renders `prompt + buffer` on the single row at
/// [bounds]. When the combined length exceeds [bounds.width] the buffer is
/// horizontally scrolled so the cursor stays visible (the prompt is always
/// in column 0 of the region; the visible buffer slides under it). This is
/// the same behaviour as zsh, fish, and bash readline.
class InputRegion extends Region {
  String _prompt = '';
  String _buffer = '';
  int _cursor = 0;
  String? _paintedText;
  String? _paintedPrompt;
  int? _paintedRow;
  int? _paintedCol;
  int? _paintedWidth;

  InputRegion(Screen screen) : super(screen);

  /// When non-null, [bounds] returns this instead of the layout's chat-box
  /// input row. Set by the coordinator to make the shared input line follow
  /// the focused panel — e.g. sit at the bottom of a spawned side panel.
  /// `null` (the default) tracks [Screen.layout.input], i.e. the primary chat.
  Rect? _boundsOverride;

  @override
  Rect get bounds => _boundsOverride ?? screen.layout.input;

  /// Repoint the input row to [rect], or `null` to track the layout's chat-box
  /// input row again. The caller erases the old row ([erase]) and repaints
  /// (via the editor) around the move; this only swaps the rectangle.
  void setBoundsOverride(Rect? rect) {
    _boundsOverride = rect;
    _paintedText = null;
  }

  /// Erase whatever is currently drawn on the input row, without resetting the
  /// editor's buffer/cursor state. Used when the input relocates so the old
  /// position doesn't leave stale pixels behind.
  void erase() {
    if (screen.passthrough) return;
    final b = bounds;
    if (b.isEmpty) return;
    screen.eraseAtAbsolute(
      row: b.row,
      col: b.col,
      n: b.width,
      moveCursor: false,
    );
    _paintedText = null;
  }

  String get prompt => _prompt;
  String get buffer => _buffer;
  int get cursor => _cursor;

  /// Render with the given prompt/buffer/cursor state. The visible terminal
  /// cursor is parked at the editing position. No-op in passthrough mode
  /// (non-interactive runs have no input row).
  void render({
    required String prompt,
    required String buffer,
    required int cursor,
  }) =>
      screen.frame(() {
        // Preempt a pending chat presentation by absorbing it into this input
        // frame: chat mutations already applied to the model paint now, and the
        // screen-global trailing timer is cancelled so it never fires a second
        // redundant render. No-op when nothing is pending.
        screen.absorbPendingChat();
        if (screen.passthrough) return;
        if (bounds.isEmpty) return;
        _prompt = prompt;
        _buffer = buffer;
        _cursor = cursor;

        final w = bounds.width;
        final promptCols = _displayWidth(prompt);
        final availForBuf = w - promptCols;

        if (availForBuf <= 0) {
          // Prompt alone fills the row; clip the prompt and park cursor at end.
          screen.putAtAbsolute(
            row: bounds.row,
            col: bounds.col,
            text: prompt,
            maxCols: w,
            moveCursor: true,
          );
          screen.parkCursorAt(bounds.row, bounds.col + w - 1);
          return;
        }

        // Pick a window into the buffer that keeps the cursor visible. The
        // cursor's column relative to the window is (cursor - start); we want
        // 0 <= (cursor - start) <= availForBuf - 1 so the cursor sits inside
        // the row, even when it's "past the last char" at the end of buffer.
        int start;
        if (buffer.length <= availForBuf || cursor < availForBuf) {
          start = 0;
        } else {
          start = cursor - availForBuf + 1;
        }
        var end = start + availForBuf;
        if (end > buffer.length) end = buffer.length;
        final visibleBuf = buffer.substring(start, end);

        final painted = prompt + visibleBuf;
        final sameGeometry = _paintedRow == bounds.row &&
            _paintedCol == bounds.col &&
            _paintedWidth == w;
        final previous = sameGeometry ? _paintedText : null;
        if (previous != painted) {
          final canPatch = previous != null &&
              _paintedPrompt == prompt &&
              !visibleBuf.contains('\x1b') &&
              !previous.substring(prompt.length).contains('\x1b');
          if (!canPatch) {
            screen.putAtAbsolute(
              row: bounds.row,
              col: bounds.col,
              text: painted,
              maxCols: w,
              moveCursor: true,
            );
          } else {
            final prefix = _commonSafePrefix(previous, painted);
            screen.patchAtAbsolute(
              row: bounds.row,
              col: bounds.col + _displayWidth(painted.substring(0, prefix)),
              text: painted.substring(prefix),
              clearCells: _displayWidth(previous.substring(prefix)),
            );
          }
          _paintedText = painted;
          _paintedPrompt = prompt;
          _paintedRow = bounds.row;
          _paintedCol = bounds.col;
          _paintedWidth = w;
        }

        final cursorCol = bounds.col + promptCols + (cursor - start);
        screen.parkCursorAt(bounds.row, cursorCol);
      });

  /// Erase the input row.
  void clear() {
    if (screen.passthrough) return;
    if (bounds.isEmpty) return;
    screen.eraseAtAbsolute(
      row: bounds.row,
      col: bounds.col,
      n: bounds.width,
      moveCursor: false,
    );
    _prompt = '';
    _buffer = '';
    _cursor = 0;
    _paintedText = null;
  }

  @override
  void handleResize() {
    if (_prompt.isEmpty && _buffer.isEmpty) return;
    _paintedText = null;
    render(prompt: _prompt, buffer: _buffer, cursor: _cursor);
  }
}

/// Floating, absolutely-positioned overlay. Used for dialogs and the
/// completion picker popup.
///
/// Caller passes the bounds (clipped to the screen). [show] writes each
/// line at its row (clipped to width); [hide] blanks the rows. After both,
/// the screen repaints any border cells that fall within the bounds.
class OverlayRegion extends Region {
  Rect _bounds;
  bool _visible = false;

  /// Phase 3: the overlay renders onto its own [BackendSurface] so it floats
  /// above chat child planes. On notcurses this is a real child plane raised
  /// to the top; on ANSI it's an emulated offset surface (same batched buffer,
  /// so output is byte-identical to the old standard-plane path). null while
  /// hidden — the surface is created on [show] and destroyed on [hide].
  BackendSurface? _surface;

  OverlayRegion(super.screen, Rect bounds)
      : _bounds = _clipToScreen(bounds, screen) {
    screen.registerOverlay(this);
  }

  @override
  Rect get bounds => _bounds;

  /// Move the overlay to [bounds]. If currently visible, clears the old
  /// rectangle first.
  void reposition(Rect bounds) {
    if (_visible) hide();
    _bounds = _clipToScreen(bounds, screen);
  }

  bool get isVisible => _visible;

  /// Render [lines] one per row. Lines beyond `bounds.height` are dropped.
  /// Each line clipped to `bounds.width`. Marks the overlay visible.
  void show(List<String> lines) {
    if (_bounds.isEmpty) return;
    _visible = true;
    // Recreate the surface each show: the bounds may have changed since the
    // last show (reposition), and destroying the prior plane clears its cells.
    _surface?.destroy();
    _surface = null;
    BackendSurface? s;
    try {
      s = screen.createSurface(_bounds);
    } catch (_) {
      // Backend can't provide a plane (test fakes / notcurses allocation
      // failure) — fall back to standard-plane writes below.
      s = null;
    }
    _surface = s;
    final surface = s;
    if (surface == null) {
      // Backend declined (e.g. passthrough, or a throwing test fake) — fall
      // back to standard-plane writes.
      _showViaStandardPlane(lines);
      return;
    }
    screen.adoptOverlaySurface(surface);
    final count = lines.length > _bounds.height ? _bounds.height : lines.length;
    for (var i = 0; i < count; i++) {
      surface.putAt(
        relRow: i,
        relCol: 0,
        text: lines[i],
        maxCols: _bounds.width,
        moveCursor: false,
      );
    }
    // Erase any leftover trailing rows from a previous (larger) overlay.
    for (var i = count; i < _bounds.height; i++) {
      surface.eraseAt(relRow: i, relCol: 0, n: _bounds.width, moveCursor: false);
    }
    // Surface writes bypass putAtAbsolute's border repair; re-assert it for
    // the touched rows so split-mode info-box borders survive hide.
    screen.scheduleBorderRepairs(
        List.generate(_bounds.height, (i) => _bounds.row + i));
  }

  void _showViaStandardPlane(List<String> lines) {
    final count = lines.length > _bounds.height ? _bounds.height : lines.length;
    for (var i = 0; i < count; i++) {
      screen.putAtAbsolute(
        row: _bounds.row + i,
        col: _bounds.col,
        text: lines[i],
        maxCols: _bounds.width,
        moveCursor: false,
      );
    }
    for (var i = count; i < _bounds.height; i++) {
      screen.eraseAtAbsolute(
        row: _bounds.row + i,
        col: _bounds.col,
        n: _bounds.width,
        moveCursor: false,
      );
    }
  }

  /// Erase every row of the overlay. Marks invisible.
  void hide() {
    if (!_visible) return;
    _visible = false;
    final s = _surface;
    if (s != null) {
      // Destroying the surface clears its plane. On ANSI the surface is an
      // offset wrapper over the shared buffer, so also erase the cells to
      // match the old standard-plane behavior (the surface's destroy is a
      // no-op there).
      if (_bounds.isEmpty) {
        s.destroy();
      } else {
        for (var i = 0; i < _bounds.height; i++) {
          s.eraseAt(relRow: i, relCol: 0, n: _bounds.width, moveCursor: false);
        }
      }
      s.destroy();
      screen.releaseOverlaySurface(s);
      _surface = null;
      screen.scheduleBorderRepairs(
          List.generate(_bounds.height, (i) => _bounds.row + i));
      return;
    }
    if (_bounds.isEmpty) return;
    for (var i = 0; i < _bounds.height; i++) {
      screen.eraseAtAbsolute(
        row: _bounds.row + i,
        col: _bounds.col,
        n: _bounds.width,
        moveCursor: false,
      );
    }
  }

  /// Release the overlay's screen registration. Hides first.
  void dispose() {
    hide();
    screen.unregisterOverlay(this);
  }

  @override
  void handleResize() {
    // The caller positions the overlay; we just clip to the new screen.
    _bounds = _clipToScreen(_bounds, screen);
    if (_visible) {
      // Caller is expected to re-show with current content. Without
      // re-show'd content, we just leave the rows as-is — the screen frame
      // redraw will have cleared most of them.
    }
  }

  static Rect _clipToScreen(Rect r, Screen screen) {
    final layout = screen.layout;
    if (r.isEmpty) return r;
    final row = r.row < 0 ? 0 : r.row;
    final col = r.col < 0 ? 0 : r.col;
    final maxBottom = layout.height - 1;
    final maxRight = layout.width - 1;
    final bottom = r.bottom > maxBottom ? maxBottom : r.bottom;
    final right = r.right > maxRight ? maxRight : r.right;
    final h = bottom - row + 1;
    final w = right - col + 1;
    if (h <= 0 || w <= 0) return Rect.empty;
    return Rect(row: row, col: col, width: w, height: h);
  }
}
