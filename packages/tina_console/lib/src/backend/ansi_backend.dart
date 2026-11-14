import 'dart:async';
import 'dart:typed_data';

import '../ansi_capable.dart';
import '../console_image.dart';
import '../image/half_block.dart';
import '../image/image_capabilities.dart';
import '../platform_env.dart';
import '../rect.dart';
import '../stdio.dart';
import '../input_latency.dart';
import 'backend_surface.dart';
import 'terminal_backend.dart';
import 'terminal_modes.dart';
import 'canvas_style.dart';

/// ANSI escape sequence implementation of [TerminalBackend].
///
/// Batches all operations into a [StringBuffer] and writes them to
/// [Stdio] on [flush]. This matches the original Screen behavior of
/// building one batched string per operation.
///
/// Since the image panel work this backend also implements
/// [RetainedImageBackend]: images render as half-block cells (two
/// pixels per cell, `▀` with top-pixel foreground and bottom-pixel
/// background), direct-color when the terminal advertises it and
/// xterm-256 with Floyd-Steinberg dithering otherwise. Terminals with
/// neither signal get a readable placeholder glyph.
class AnsiBackend
    implements
        TerminalBackend,
        TerminalAttentionBackend,
        BackendDiagnostics,
        CursorBackend,
        CanvasBackend,
        BackendDamageSource,
        RetainedImageBackend {
  CanvasStyle _canvas = const CanvasStyle();
  bool _usedCanvas = false;
  String? _cursorColor;

  @override
  void setCanvasStyle(
      {required String foreground, required String background}) {
    if (!_ansi.useColor) return;
    if (_canvas.isActive) _buf.write('\x1b[0m');
    _canvas = CanvasStyle(foreground: foreground, background: background);
    _usedCanvas |= _canvas.isActive;
    final cursorColor = _canvas.cursorColor;
    if (cursorColor != _cursorColor) {
      _buf.write(CanvasStyle.cursorSequence(cursorColor));
      _cursorColor = cursorColor;
    }
  }

  final Stdio _io;
  final AnsiCapable _ansi;
  final StringBuffer _buf = StringBuffer();
  int _frameDepth = 0;
  bool _flushPending = false;

  /// Frames that have actually reached the terminal. Bumped in [_flushNow] so
  /// the stuck check can tell "nothing is being drawn" from "nothing to draw".
  int _presentedFrames = 0;

  /// Whether cells have changed since the last presentation. The buffer holds
  /// the pending writes, so a non-empty buffer is exactly "dirty".
  bool _gridDirty = false;

  @override
  void Function(Rect? bounds)? onDamage;

  (int, int)? _cursor;
  (int, int)? _savedCursor;
  bool _cursorVisible = true;
  static final _sgr = RegExp(r'\x1b\[[0-9;:]*m');
  static final _controls = RegExp(r'[\x00-\x1f\x7f-\x9f]');

  AnsiBackend(
      {required Stdio io, required AnsiCapable ansi, ImageColorMode? imageColor})
      : _io = io,
        _ansi = ansi,
        _imageColorOverride = imageColor;

  // -- Retained images (half-block cells) ---------------------------------

  /// Image color mode override (tests pin this). Null: detect from the
  /// environment (`TINA_IMAGE_COLOR` beats `COLORTERM` beats `TERM`).
  final ImageColorMode? _imageColorOverride;
  ImageColorMode get imageColorMode {
    final pinned = _imageColorOverride;
    if (pinned != null) return pinned;
    if (!_ansi.useColor) return ImageColorMode.mono;
    return ImageColorCapabilities.detect(
        override: platformEnv('TINA_IMAGE_COLOR'),
        colorterm: platformEnv('COLORTERM'),
        term: platformEnv('TERM'));
  }

  /// Cell extents painted for an owner, so a later update or clear can
  /// erase exactly what the image covered (ANSI has no planes; the cells
  /// live on the shared grid underneath the region's text).
  final _imagePainted = <Object, List<(int, int, int)>>{};

  @override
  ImageCellSize get imageCellSize =>
      imageColorMode == ImageColorMode.mono ? const ImageCellSize(1, 1) : ImageCellSize.halfBlock;

  @override
  bool updateImages(Object owner, List<ImagePlacement> images,
      {BackendSurface? targetSurface}) {
    final painted = _imagePainted[owner];
    if (painted != null) {
      for (final (row, col, len) in painted) {
        eraseCells(row, col, len);
      }
    }
    final next = <(int, int, int)>[];
    final mode = imageColorMode;
    for (final placement in images) {
      if (mode == ImageColorMode.mono) {
        // No usable image colors: one readable placeholder per image,
        // same degradation the pre-panel ANSI path had.
        moveCursor(placement.row, placement.column);
        writeText('\x1b[2m▣\x1b[0m');
        next.add((placement.row, placement.column, 1));
        continue;
      }
      final cells = placement.image.cells;
      final width = placement.columns * cells.width;
      final height = placement.rows * cells.height;
      final top = placement.sourceRow * cells.height;
      if (width < 1 || height < 1) continue;
      final cropped = placement.image.cropRgba(top: top, width: width, height: height);
      final raster = ImageRaster(
          rgba: cropped.buffer
              .asUint32List(cropped.offsetInBytes, width * height),
          width: width,
          height: height,
          cells: cells);
      final rows = renderHalfBlockRows(raster, truecolor: mode == ImageColorMode.truecolor);
      for (var i = 0; i < rows.length && i < placement.rows; i++) {
        final row = placement.row + i;
        moveCursor(row, placement.column);
        writeText(rows[i]);
        // Erase extent is in CELLS: the row string carries SGR escapes
        // that must not count toward the painted width.
        next.add((row, placement.column, placement.columns));
      }
    }
    _imagePainted[owner] = next;
    return next.isNotEmpty;
  }

  @override
  void clearImages(Object owner) {
    final painted = _imagePainted.remove(owner);
    if (painted == null) return;
    for (final (row, col, len) in painted) {
      eraseCells(row, col, len);
    }
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
  int get openFrames => _frameDepth;

  @override
  bool get flushPending => _flushPending;

  @override
  bool get gridDirty => _gridDirty;

  @override
  int get presentedFrames => _presentedFrames;

  @override
  void moveCursor(int row, int col) {
    if (_cursor == (row, col)) return;
    _buf.write('\x1b[${row + 1};${col + 1}H');
    _cursor = (row, col);
  }

  @override
  void parkCursor(int row, int col) => moveCursor(row, col);

  @override
  void setCursorVisible(bool visible) {
    if (_cursorVisible == visible) return;
    _cursorVisible = visible;
    _buf.write(visible ? '\x1b[?25h' : '\x1b[?25l');
  }

  @override
  void eraseCells(int row, int col, int n) {
    if (n <= 0) return;
    if (OpCounters.enabled) OpCounters.instance.gridWrites++;
    _gridDirty = true;
    _buf.write(_canvas.reset);
    moveCursor(row, col);
    _buf.write('\x1b[${n}X');
    onDamage?.call(Rect(row: row, col: col, width: n, height: 1));
  }

  @override
  void writeText(String text) {
    if (text.isEmpty) return;
    if (OpCounters.enabled) OpCounters.instance.gridWrites++;
    _gridDirty = true;
    _buf.write(_canvas.apply(text));
    // Do not guess the terminal's cursor advancement (wide glyphs, autowrap
    // and control sequences differ between emulators). A save/restore pair
    // recovers the known editing position after background drawing.
    final plain = text.replaceAll(_sgr, '');
    if (plain.isNotEmpty) {
      final cursor = _cursor;
      final columns = _io.terminalColumns;
      onDamage?.call(
          cursor != null && !plain.contains(_controls) && cursor.$2 < columns
              ? Rect(
                  row: cursor.$1,
                  col: cursor.$2,
                  width: columns - cursor.$2,
                  height: 1)
              : null);
      _cursor = null;
    }
  }

  @override
  void saveCursor() {
    _buf.write('\x1b7');
    _savedCursor = _cursor;
  }

  @override
  void restoreCursor() {
    _buf.write('\x1b8');
    _cursor = _savedCursor;
  }

  @override
  void flush() {
    if (_frameDepth > 0) {
      _flushPending = true;
      return;
    }
    _flushNow();
  }

  void _flushNow() {
    if (_buf.isNotEmpty) {
      _io.write(_buf.toString());
      _buf.clear();
      _gridDirty = false;
      _presentedFrames++;
      if (OpCounters.enabled) OpCounters.instance.renderCalls++;
    }
    InputLatency.stage(LatencyStage.flushCompleted);
  }

  // -- Screen lifecycle ---------------------------------------------------

  @override
  void requestAttention() {
    _buf.write('\x07');
    flush();
  }

  @override
  void enterAltScreen() {
    _buf.write('\x1b[?1049h');
    // Let the terminal handle drag selection without an override modifier.
    // Clear tracking inherited from a previous app as well.
    _buf.write(disableMouseReporting);
    _cursor = _savedCursor = null;
  }

  @override
  void leaveAltScreen() {
    setCursorVisible(true);
    _buf.write(disableMouseReporting);
    if (_cursorColor != null) {
      _buf.write(CanvasStyle.cursorSequence(null));
      _cursorColor = null;
    }
    if (_usedCanvas) _buf.write('\x1b[0m');
    _buf.write('\x1b[?1049l');
    _cursor = _savedCursor = null;
  }

  // -- Bracketed paste ----------------------------------------------------

  bool _bracketedPasteEnabled = false;

  @override
  void enableBracketedPaste() {
    if (_bracketedPasteEnabled) return;
    _bracketedPasteEnabled = true;
    _buf.write('\x1b[?2004h');
  }

  @override
  void disableBracketedPaste() {
    if (!_bracketedPasteEnabled) return;
    _bracketedPasteEnabled = false;
    _buf.write('\x1b[?2004l');
  }

  // -- Color & input ------------------------------------------------------

  // ANSI paints each chat write synchronously; it never touches the
  // presentation scheduler.
  @override
  bool get coalescesPaints => false;

  // No retained damage model — every frame is re-emitted from the retained
  // row model, so a resize needs no explicit re-sync.
  @override
  void refresh() {}

  @override
  bool get supportsColor => _ansi.useColor;

  @override
  String colorize(String code, String text) {
    if (!_ansi.useColor) return text;
    return '\x1b[${code}m$text\x1b[0m';
  }

  @override
  Stream<List<int>> get stdin => _io.stdin;

  @override
  int get terminalColumns => _io.terminalColumns;

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
    // The non-retained image API: no pixel-graphics protocol, so a single
    // dimmed placeholder cell keeps the method total for headless/CI runs.
    // Retained chat/panel images go through updateImages above (half-block
    // cells). targetSurface is ignored — ANSI has no child planes, so there
    // is no surface to parent the image onto.
    moveCursor(row, col);
    writeText('\x1b[2m▣\x1b[0m'); // dim placeholder glyph
  }

  @override
  BackendSurface createSurface(Rect bounds) => AnsiBackendSurface(this, bounds);
}

/// [BackendSurface] for the ANSI backend.
///
/// ANSI has no real planes, so a surface is emulated as a rect offset over the
/// shared batched buffer: relative coordinates are translated to absolute and
/// routed through the parent [AnsiBackend]'s positioning/erase/write methods.
/// The next [AnsiBackend.flush] emits them along with everything else, so
/// there is still a single sink. [moveTo]/[resize] are bookkeeping (the owner
/// re-renders content at the new geometry); [raiseToTop]/[lowerToBottom] are
/// no-ops because ANSI has no z-order.
class AnsiBackendSurface implements BackendSurface {
  final AnsiBackend _backend;
  Rect _bounds;

  AnsiBackendSurface(this._backend, this._bounds);

  @override
  Rect get bounds => _bounds;

  int _row(int rel) => _bounds.row + rel;
  int _col(int rel) => _bounds.col + rel;

  @override
  void putAt({
    required int relRow,
    required int relCol,
    required String text,
    required int maxCols,
    required bool moveCursor,
    int? clearCells,
  }) {
    final columns = clippedSurfaceColumns(_bounds, relRow, relCol, maxCols);
    if (columns == 0) return;
    final r = _row(relRow);
    final c = _col(relCol);
    final clipped = clipToVisibleColumns(text, columns);
    if (moveCursor) {
      _backend.moveCursor(r, c);
    } else {
      _backend.saveCursor();
      _backend.moveCursor(r, c);
    }
    // Bounded by the caller's previous-extent snapshot like the notcurses
    // surface (tin-p8k2). Here it is purely an output-size optimization —
    // every write is explicitly addressed, so there is no cursor-drift
    // hazard — but keeping the two surfaces symmetric means one emit path.
    _backend.eraseCells(r, c, (clearCells ?? columns).clamp(0, columns));
    _backend.writeText(clipped);
    if (!moveCursor) _backend.restoreCursor();
    _backend.flush();
  }

  @override
  void eraseAt({
    required int relRow,
    required int relCol,
    required int n,
    required bool moveCursor,
  }) {
    final columns = clippedSurfaceColumns(_bounds, relRow, relCol, n);
    if (columns == 0) return;
    final r = _row(relRow);
    final c = _col(relCol);
    if (!moveCursor) _backend.saveCursor();
    _backend.eraseCells(r, c, columns);
    if (!moveCursor) _backend.restoreCursor();
    _backend.flush();
  }

  @override
  void moveTo(int row, int col) {
    _bounds =
        Rect(row: row, col: col, width: _bounds.width, height: _bounds.height);
  }

  @override
  void resize(int width, int height) {
    _bounds =
        Rect(row: _bounds.row, col: _bounds.col, width: width, height: height);
  }

  @override
  void raiseToTop() {}

  @override
  void lowerToBottom() {}

  @override
  bool scrollRows(int count) => false; // ANSI has no native scroll; redraw.

  @override
  void destroy() {}
}
