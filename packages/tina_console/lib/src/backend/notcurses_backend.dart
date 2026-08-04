import 'dart:async';
import 'dart:typed_data';

import 'package:dart_notcurses/dart_notcurses.dart' as nc;

import '../rect.dart';
import '../stdio.dart';
import '../styled_text.dart';
import 'backend_surface.dart';
import '../input_latency.dart';
import 'input_backend.dart';
import 'notcurses_input_backend.dart';
import 'terminal_backend.dart';

/// The thin slice of notcurses API that [NotcursesBackend] depends on.
///
/// Pulling these calls behind an interface lets tests substitute a
/// recording fake — without it, every assertion about cursor advancement,
/// stop-guard correctness, or palette-based colour detection would need a
/// live libnotcurses, which CI doesn't have.
/// A notcurses plane exposed as the minimum surface needed to render
/// SGR-styled text: place strings at (row, col) and toggle style / colour
/// state. Both [NotcursesPlatform] (standard plane) and the per-child-plane
/// adapter used by [NotcursesBackendSurface] implement this so
/// [_emitSgrStyled] can drive either.
/// A notcurses plane exposed as the string-placement + style surface used by
/// the shared SGR walker. Implements [StyledStyleSink] so the single source of
/// SGR semantics in [applySgrCode] (styled_text.dart) can drive either this or
/// a recording fake.
abstract class _SgrSink implements StyledStyleSink {
  void putStrYX(int row, int col, String text);
}

abstract class NotcursesPlatform implements _SgrSink {
  /// Write [text] at ([row], [col]) on the standard plane.
  @override
  void putStrYX(int row, int col, String text);

  /// Render and rasterize the standard pile.
  bool render();

  /// Re-emit the last rasterized frame in full, bypassing damage tracking
  /// (recovery for cells the terminal dropped even though the grid is right).
  bool refresh();

  /// Show the hardware cursor at ([y], [x]).
  void cursorEnable(int y, int x);

  /// Hide the hardware cursor, restoring the cell beneath it before a park-row
  /// transition is rendered.
  void cursorDisable();

  /// Destroy the notcurses context. After this, no other method on the
  /// platform is safe to call.
  void stop();

  /// Reported palette size. Anything > 1 means the terminal can colour.
  int paletteSize();

  /// Width of the standard plane in columns.
  int planeColumns();

  /// The terminal's default background colour as a 24-bit RGB value, or null
  /// if the terminal does not advertise a default.
  int? defaultBackground();

  /// Write a raw byte sequence directly to the controlling terminal
  /// (`/dev/tty`), bypassing notcurses' retained-mode output. Used for
  /// terminal mode toggles like bracketed paste that notcurses has no API
  /// for. Silently no-ops when there is no controlling terminal.
  void writeRawToTty(String s);

  /// Build a paired [InputBackend] over this platform's notcurses context.
  InputBackend createInputBackend();

  /// Create a child plane of the standard plane at [bounds] and wrap it as a
  /// [BackendSurface]. Returns null if the plane cannot be created. Only the
  /// live platform supports this; the recording fake returns null.
  BackendSurface? createSurface(Rect bounds);

  /// The standard plane — the parent for image child-plane blits.
  /// Nullable so recording fakes (no live libnotcurses) can return null.
  nc.Plane? get plane;

  /// The notcurses context backing this platform.  Nullable for fakes.
  nc.NotCurses? get notc;
}

/// Real-libnotcurses implementation of [NotcursesPlatform]. Only constructed
/// from [NotcursesBackend.create]; tests never instantiate this.
class _LiveNotcursesPlatform implements NotcursesPlatform {
  final nc.NotCurses _nc;
  final nc.Plane _plane;

  /// The standard plane — the parent for image child-plane blits.
  @override
  nc.Plane get plane => _plane;

  /// The notcurses context backing this platform.
  @override
  nc.NotCurses get notc => _nc;

  _LiveNotcursesPlatform._(this._nc, this._plane);

  factory _LiveNotcursesPlatform.init() {
    // suppressBanners: skip the version/performance banners that notcurses
    // prints during init and stop.
    //
    // NOTE: do NOT add OptionFlags.drainInput here. Despite the name, it does
    // not mean "drain stale query responses during init" — it means "this
    // client will never read keyboard input." With it set, notcurses discards
    // every key event (src/lib/in.c load_ncinput / internal_get) and
    // get_nblock returns -1, so NotCursesInputBackend receives no input at
    // all and the TUI is dead to the keyboard. The startup query-response
    // leak is handled instead by a short post-init drain in
    // NotCursesInputBackend.
    final nc_ = nc.NotCurses(nc.CursesOptions(
      loglevel: nc.LogLevel.silent,
      flags: nc.OptionFlags.suppressBanners,
    ));
    if (nc_.notInitialized) {
      throw StateError('Failed to initialize notcurses');
    }
    return _LiveNotcursesPlatform._(nc_, nc_.stdplane());
  }

  @override
  void putStrYX(int row, int col, String text) {
    if (OpCounters.enabled) OpCounters.instance.gridWrites++;
    _plane.putStrYX(row, col, text);
  }

  @override
  void setStyles(int stylebits) => _plane.setStyles(stylebits);

  @override
  void setFgRGB(int hex) {
    _plane.setFgRGB(hex);
  }

  @override
  void setBgRGB(int hex) {
    _plane.setBgRGB(hex);
  }

  @override
  void setFgDefault() => _plane.setFgDefault();

  @override
  void setBgDefault() => _plane.setBgDefault();

  @override
  bool render() => _nc.render();

  @override
  bool refresh() {
    if (OpCounters.enabled) OpCounters.instance.refreshCalls++;
    return _nc.refresh();
  }

  @override
  void cursorEnable(int y, int x) => _nc.cursorEnable(y: y, x: x);

  @override
  void cursorDisable() => _nc.cursorDisable();

  @override
  void stop() => _nc.stop();

  @override
  int paletteSize() => _nc.paletteSize();

  @override
  int? defaultBackground() => _nc.defaultBackground();

  @override
  int planeColumns() => _plane.dimx();

  @override
  void writeRawToTty(String s) => _nc.writeRawToTty(s);

  @override
  InputBackend createInputBackend() => NotcursesInputBackend.fromNotcurses(_nc);

  @override
  BackendSurface? createSurface(Rect bounds) {
    final child = _plane.create(nc.PlaneOptions(
      y: bounds.row,
      x: bounds.col,
      rows: bounds.height,
      cols: bounds.width,
      name: 'panel',
    ));
    if (child == null) return null;
    return NotcursesBackendSurface(child, this, bounds);
  }
}

/// Notcurses implementation of [TerminalBackend].
///
/// Uses the dart_notcurses FFI bindings to render through the notcurses
/// library. This is a retained-mode backend — writes accumulate in the
/// notcurses cell grid and are sent to the terminal on [flush] via
/// [nc.NotCurses.render].
class NotcursesBackend implements TerminalBackend {
  final Stdio _io;
  final NotcursesPlatform _platform;

  /// Saved cursor state for [saveCursor]/[restoreCursor].
  int _savedRow = 0;
  int _savedCol = 0;

  /// Whether [_savedRow]/[_savedCol] are valid.
  bool _hasSaved = false;

  /// Current logical cursor position (used by [writeText]).
  int _cursorRow = 0;
  int _cursorCol = 0;

  /// Hardware cursor target. Drawing operations never mutate this state.
  int _parkRow = 0;
  int _parkCol = 0;

  int _frameDepth = 0;
  bool _flushPending = false;
  bool _gridDirty = false;
  int presentationCount = 0;

  /// The hardware cursor's previously presented row.
  int? _lastParkRow;

  /// Whether [enterAltScreen] has been called.
  bool _inAltScreen = false;

  /// Set once [NotcursesPlatform.stop] has been called. After this, every
  /// terminal-touching method becomes a no-op so callers that follow
  /// notcurses' "leave alt screen" with a `flush()` (as
  /// [Screen.leaveAltScreen] does) don't dereference the destroyed context.
  bool _stopped = false;

  NotcursesBackend._(this._io, this._platform);

  /// Create and return a [NotcursesBackend] backed by libnotcurses.
  ///
  /// Throws if the notcurses library cannot be initialized.
  static NotcursesBackend create({required Stdio io}) {
    return NotcursesBackend._(io, _LiveNotcursesPlatform.init());
  }

  /// Test-only constructor: inject a fake [NotcursesPlatform] so the
  /// backend's state machine can be exercised without libnotcurses.
  factory NotcursesBackend.forTesting({
    required Stdio io,
    required NotcursesPlatform platform,
  }) =>
      NotcursesBackend._(io, platform);

  /// Build a paired [InputBackend] that polls the same notcurses context
  /// this backend owns. Throws after the backend has been stopped — callers
  /// must construct the input backend before tearing the screen down.
  InputBackend createInputBackend() {
    if (_stopped) {
      throw StateError('NotcursesBackend has been stopped.');
    }
    return _platform.createInputBackend();
  }

  // -- Cursor positioning -------------------------------------------------

  @override
  void beginFrame() {
    if (OpCounters.enabled) OpCounters.instance.logicalFrames++;
    _frameDepth++;
  }

  @override
  void endFrame() {
    if (_frameDepth == 0) return;
    _frameDepth--;
    if (_frameDepth == 0 && _flushPending) {
      _flushPending = false;
      _flushNow();
    }
  }

  @override
  void moveCursor(int row, int col) {
    if (_stopped) return;
    _cursorRow = row;
    _cursorCol = col;
    // Notcurses uses positioned writes (putStrYX), so we just track the
    // position. The actual cursor is set on flush via cursorEnable.
  }

  @override
  void parkCursor(int row, int col) {
    if (_stopped) return;
    _parkRow = row;
    _parkCol = col;
  }

  @override
  void eraseCells(int row, int col, int n) {
    if (_stopped) return;
    // Write n spaces at (row, col). This clears the cells in the retained
    // buffer — no flush needed yet.
    _platform.putStrYX(row, col, ' ' * n);
    _gridDirty = true;
    _cursorRow = row;
    _cursorCol = col;
  }

  @override
  void writeText(String text) {
    if (_stopped) return;
    _cursorCol = _emitSgrStyled(_platform, _cursorRow, _cursorCol, text);
    _gridDirty = true;
  }

  @override
  void saveCursor() {
    _savedRow = _cursorRow;
    _savedCol = _cursorCol;
    _hasSaved = true;
  }

  @override
  void restoreCursor() {
    if (_hasSaved) {
      _cursorRow = _savedRow;
      _cursorCol = _savedCol;
    }
  }

  @override
  void flush() {
    if (_stopped) return;
    if (_frameDepth > 0) {
      _flushPending = true;
      return;
    }
    _flushNow();
  }

  void _flushNow() {
    if (_stopped) return;
    final parkRowChanged = _parkRow != _lastParkRow;
    if (parkRowChanged) {
      // Hiding first asks the terminal to restore the cell under the old
      // hardware cursor. This avoids the dropped-border artifact without a
      // full-screen notcurses_refresh().
      _platform.cursorDisable();
    }
    if (_gridDirty) {
      presentationCount++;
      _platform.render();
      if (OpCounters.enabled) OpCounters.instance.renderCalls++;
      _gridDirty = false;
    }
    _lastParkRow = _parkRow;
    _platform.cursorEnable(_parkRow, _parkCol);
    InputLatency.stage(LatencyStage.flushCompleted);
  }

  void _surfaceMutated() {
    _gridDirty = true;
    flush();
  }

  // -- Screen lifecycle ---------------------------------------------------

  @override
  void enterAltScreen() {
    if (_stopped) return;
    // No-op: the notcurses constructor (NotCurses(opts)) already entered
    // the alternate screen. We just track state so leaveAltScreen knows
    // whether stop() is its responsibility.
    _inAltScreen = true;
  }

  @override
  void leaveAltScreen() {
    if (!_inAltScreen || _stopped) return;
    _inAltScreen = false;
    _platform.stop();
    // After stop, the platform is unusable: every method that touches the
    // terminal (flush, moveCursor, eraseCells, writeText, enterAltScreen)
    // becomes a no-op. Screen.leaveAltScreen() calls flush() right after
    // this — that call is now safe.
    _stopped = true;
  }

  // -- Bracketed paste ----------------------------------------------------

  bool _bracketedPasteEnabled = false;

  @override
  void enableBracketedPaste() {
    if (_stopped || _bracketedPasteEnabled) return;
    _bracketedPasteEnabled = true;
    // notcurses has no API for DECSET 2004; write the escape directly to the
    // controlling tty (its output FILE* isn't exposed to Dart, and stdout
    // interleaves badly with notcurses render output).
    _platform.writeRawToTty('\x1b[?2004h');
  }

  @override
  void disableBracketedPaste() {
    if (_stopped || !_bracketedPasteEnabled) return;
    _bracketedPasteEnabled = false;
    _platform.writeRawToTty('\x1b[?2004l');
  }

  // Retained-mode backend: chat writes coalesce into timer-bounded presents
  // via the screen-global scheduler instead of painting synchronously.
  @override
  bool get coalescesPaints => !_stopped;

  // -- Color & input ------------------------------------------------------

  @override
  bool get supportsColor {
    if (_stopped) return false;
    try {
      // canTrueColor() answers "24-bit RGB?" — too strict; 256-colour and
      // 8-colour terminals still support SGR codes. paletteSize() is the
      // looser, correct check.
      return _platform.paletteSize() > 1;
    } catch (_) {
      return true; // Assume color support if query fails.
    }
  }

  @override
  String colorize(String code, String text) {
    // Wrap in SGR the same way the ANSI backend does. Notcurses'
    // putStr doesn't interpret embedded SGR itself — `_emitSgrStyled`
    // parses it out at the backend boundary and calls the plane-styling
    // APIs on either the standard plane or a child surface's plane.
    if (!supportsColor) return text;
    return '\x1b[${code}m$text\x1b[0m';
  }

  @override
  Stream<List<int>> get stdin => _io.stdin;

  @override
  int get terminalColumns => _platform.planeColumns();

  /// The terminal's default background colour as 24-bit RGB, or null if
  /// the terminal does not advertise a default (e.g. a truecolour palette
  /// is in use).
  int? get defaultBackground => _platform.defaultBackground();

  @override
  BackendSurface createSurface(Rect bounds) {
    if (_stopped) {
      throw StateError('NotcursesBackend has been stopped.');
    }
    final surface = _platform.createSurface(bounds);
    if (surface == null) {
      throw StateError(
          'notcurses could not create a child plane for the surface.');
    }
    if (surface is NotcursesBackendSurface) {
      surface._requestPresent = _surfaceMutated;
    }
    return surface;
  }

  @override
  void renderImageAbsolute({
    required int row,
    required int col,
    required Uint32List rgba,
    required int width,
    required int height,
    required int maxCols,
    BackendSurface? targetSurface,
  }) {
    if (_stopped || width <= 0 || height <= 0) return;
    // Parent the image onto the target chat plane when supplied (so the picture
    // stacks above that panel's chat surface), else onto the standard plane.
    final chatSurface = targetSurface is NotcursesBackendSurface
        ? targetSurface
        : null;
    final plane = chatSurface?._plane ?? _platform.plane;
    final notc = chatSurface?._platform.notc ?? _platform.notc;
    if (plane == null || notc == null)
      return; // recording fake / no pixel path
    // Reinterpret the 32-bit RGBA pixels as a byte buffer for ncvisual_from_rgba.
    final bytes = rgba.buffer.asUint8List(0, width * height * 4);
    final visual = nc.Visual.fromRGBA(bytes, height, width * 4, width);
    final vopts = nc.VisualOptions(
      plane: plane,
      y: row,
      x: col,
      blitter: _pixelBlitter(notc),
      scaling: nc.Scale.none,
      flags: nc.VisualOptionFlags.childplane,
    );
    visual.blit(notc, vopts);
    visual.destroy();
    _gridDirty = true;
  }

  /// Pick the best available blitter: pixel-accurate graphics when the terminal
  /// supports them, else fall back through the rasterized-block ladder that
  /// notcurses itself uses for NCBLIT_DEFAULT.
  int _pixelBlitter(nc.NotCurses nc_) {
    if (nc_.canPixel()) return nc.Blitter.pixel;
    if (nc_.canHalfBlock()) return nc.Blitter.blit_3x2;
    return nc.Blitter.blit_1x1;
  }
}

/// [BackendSurface] backed by a real notcurses child plane.
///
/// Each write goes to the plane at relative coordinates; [render] is called so
/// the change appears on the next rasterize (the hardware cursor is left
/// wherever the backend last placed it — typically the input editor — since
/// plane writes don't touch the tracked logical cursor). [raiseToTop]/
/// [lowerToBottom] use real z-ordering. Visibility is handled at the
/// [Panel]/[Screen] layer, not here (notcurses has no hide/show).
class NotcursesBackendSurface implements BackendSurface {
  final nc.Plane _plane;
  final NotcursesPlatform _platform;
  Rect _bounds;
  bool _destroyed = false;
  void Function()? _requestPresent;

  /// Whether [_plane.setScrolling] has been enabled. notcurses requires a
  /// plane to be a "scrolling plane" before [nc.Plane.scrollUp] succeeds
  /// (otherwise it returns an error); set lazily on the first [scrollRows].
  bool _scrollingEnabled = false;

  NotcursesBackendSurface(this._plane, this._platform, this._bounds);

  void _present() {
    final request = _requestPresent;
    if (request != null) {
      request();
    } else {
      _platform.render();
    }
  }

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
    if (_destroyed) return;
    // Same swallow bug as writeText: the child plane's putStr silently
    // drops any write containing embedded SGR. Route through the shared
    // SGR walker, targeting THIS surface's child plane.
    final clipped = clipToVisibleColumns(text, maxCols);
    // Erase the destination span first (default style) so a shorter new text
    // doesn't leave the previous row's stale suffix visible — mirrors what
    // Screen.putAtAbsolute does (eraseCells then writeText). Without this a
    // full-row rewrite of chat would keep trailing cells from the prior row.
    //
    // Phase 4 boundary invariant: a child-plane putAt always starts from the
    // default baseline (setFgDefault/setBgDefault/setStyles(0)) before any SGR
    // the text carries. A partial write can therefore never inherit a prior
    // region's leftover style — each emit is self-contained. The ANSI surface
    // path relies on the same guarantee via putAtAbsolute's eraseCells.
    final sink = _PlaneSgrSink(_plane);
    sink
      ..setFgDefault()
      ..setBgDefault()
      ..setStyles(0);
    sink.putStrYX(relRow, relCol, ' ' * maxCols);
    _emitSgrStyled(sink, relRow, relCol, clipped);
    _present();
  }

  @override
  void eraseAt({
    required int relRow,
    required int relCol,
    required int n,
    required bool moveCursor,
  }) {
    if (_destroyed) return;
    final sink = _PlaneSgrSink(_plane)
      ..setFgDefault()
      ..setBgDefault()
      ..setStyles(0);
    sink.putStrYX(relRow, relCol, ' ' * n);
    _present();
  }

  @override
  bool scrollRows(int count) {
    if (count <= 0) return true; // nothing to do; caller need not redraw
    if (_destroyed) return false;
    if (!_scrollingEnabled) {
      _plane.setScrolling(true);
      _scrollingEnabled = true;
    }
    // ncplane_scrollup returns the number of lines scrolled (>= 0) on
    // success, or a negative error. Treat any non-negative result as success.
    final scrolled = _plane.scrollUp(count);
    _present();
    return scrolled >= 0;
  }

  @override
  void moveTo(int row, int col) {
    if (_destroyed) return;
    _bounds =
        Rect(row: row, col: col, width: _bounds.width, height: _bounds.height);
    _plane.moveYX(row, col);
    _present();
  }

  @override
  void resize(int width, int height) {
    if (_destroyed) return;
    _bounds =
        Rect(row: _bounds.row, col: _bounds.col, width: width, height: height);
    // Discard content (zero-size keep region); the owner re-renders.
    _plane.resize(0, 0, 0, 0, 0, 0, height, width);
    _present();
  }

  @override
  void raiseToTop() {
    if (!_destroyed) _plane.moveTop();
  }

  @override
  void lowerToBottom() {
    if (!_destroyed) _plane.moveBottom();
  }

  @override
  void destroy() {
    if (_destroyed) return;
    _destroyed = true;
    _plane.destroy();
  }
}

/// Wraps a live [nc.Plane] as an [_SgrSink] so [_emitSgrStyled] can drive a
/// child plane the same way it drives [NotcursesPlatform]'s standard plane.
class _PlaneSgrSink implements _SgrSink {
  final nc.Plane _plane;
  _PlaneSgrSink(this._plane);

  @override
  void putStrYX(int row, int col, String text) =>
      _plane.putStrYX(row, col, text);

  @override
  void setStyles(int stylebits) => _plane.setStyles(stylebits);

  @override
  void setFgRGB(int hex) {
    _plane.setFgRGB(hex);
  }

  @override
  void setBgRGB(int hex) {
    _plane.setBgRGB(hex);
  }

  @override
  void setFgDefault() => _plane.setFgDefault();

  @override
  void setBgDefault() => _plane.setBgDefault();
}

/// Emit [text] to [sink] starting at ([row], [startCol]), parsing any
/// embedded SGR (`\x1b[…m`) into plane-styling calls on the sink. Returns
/// the column past the last plain-text run — equivalent to
/// `startCol + visibleColumns(text)` when [text] is well-formed.
///
/// Phase 4: styled strings are parsed once into a cached list of [StyledRun]s
/// (adjacent same-state runs collapsed), then emitted run-by-run. Plain strings
/// (no ESC) bypass the cache and fall back to [_emitSgrStyledWalker], so byte
/// output is byte-identical to the pre-Phase-4 emitter in every case.
///
/// notcurses' `putStr` silently drops any write containing embedded SGR
/// (see dart_notcurses/test/sgr_test.dart), so every plane target — the
/// standard plane via [NotcursesPlatform], any child plane via
/// [_PlaneSgrSink] — must strip SGR before writing.
int _emitSgrStyled(_SgrSink sink, int row, int startCol, String text) {
  final runs = styledRunCache.get(text);
  if (runs == null) {
    // Plain string — no SGR to collapse. Fall back to the original walker so
    // no baseline resets are added (would diverge from pre-Phase-4 output).
    return _emitSgrStyledWalker(sink, row, startCol, text);
  }
  OpCounters.instance.styledRunEmits++;

  var col = startCol;
  for (final run in runs) {
    for (final fn in run.establishCalls) {
      fn(sink);
    }
    if (run.text.isNotEmpty) {
      sink.putStrYX(row, col, run.text);
      col += run.text.length;
    }
  }
  return col;
}

/// Original SGR walker, retained as the byte-identical fallback for plain
/// strings (which the parse cache bypasses). Parses CSI in place without a
/// preceding baseline reset, matching pre-Phase-4 output exactly.
int _emitSgrStyledWalker(_SgrSink sink, int row, int startCol, String text) {
  var col = startCol;
  final buf = StringBuffer();
  var i = 0;
  while (i < text.length) {
    final cu = text.codeUnitAt(i);
    if (cu == 0x1b && i + 1 < text.length && text.codeUnitAt(i + 1) == 0x5b) {
      if (buf.isNotEmpty) {
        final span = buf.toString();
        sink.putStrYX(row, col, span);
        col += span.length;
        buf.clear();
      }
      var j = i + 2;
      while (j < text.length) {
        final c = text.codeUnitAt(j);
        if (c >= 0x40 && c <= 0x7e) break;
        j++;
      }
      if (j >= text.length) {
        // Malformed trailing escape — drop.
        return col;
      }
      if (text.codeUnitAt(j) == 0x6d /* 'm' */) {
        _applySgr(sink, text.substring(i + 2, j));
      }
      // Non-SGR CSI (cursor movement, etc.) is dropped silently.
      i = j + 1;
    } else {
      buf.writeCharCode(cu);
      i++;
    }
  }
  if (buf.isNotEmpty) {
    final span = buf.toString();
    sink.putStrYX(row, col, span);
    col += span.length;
  }
  return col;
}

/// Apply the SGR parameters between `\x1b[` and the trailing `m` to [sink].
/// Empty [params] is treated as `0` (full reset), matching ANSI. Empty
/// [params] is treated as `0` (full reset), matching ANSI. Style bits within
/// a single sequence are OR'd before the setStyles call, so `\x1b[1;4m` yields
/// bold+underline in one step, not two overwrites. Unknown codes are skipped
/// silently.
///
/// The per-code semantics live in the shared [applySgrCode] (styled_text.dart)
/// so the live emitter and the parse-cache parser can never drift; this
/// wrapper just drives [sink] (a [StyledStyleSink]) with a throwaway state.
void _applySgr(_SgrSink sink, String params) {
  if (OpCounters.enabled) OpCounters.instance.styleChanges++;
  final state = SgrState();
  applySgrCode(params.isEmpty ? const ['0'] : params.split(';'), sink, state);
}

/// Count visible columns in [text], skipping over CSI escape sequences
/// (`\x1b[...<final>`). Each non-escape rune counts as one column — wide
/// glyphs are NOT counted at width 2, matching how tina_console clips its
/// own writes. Exposed for tests.
int visibleColumns(String text) {
  var visible = 0;
  var i = 0;
  while (i < text.length) {
    final cu = text.codeUnitAt(i);
    if (cu == 0x1b) {
      i++;
      if (i < text.length && text.codeUnitAt(i) == 0x5b) {
        i++;
        while (i < text.length) {
          final c = text.codeUnitAt(i);
          i++;
          if (c >= 0x40 && c <= 0x7e) break; // CSI final byte
        }
      } else if (i < text.length) {
        i++;
      }
      continue;
    }
    visible++;
    i++;
  }
  return visible;
}
