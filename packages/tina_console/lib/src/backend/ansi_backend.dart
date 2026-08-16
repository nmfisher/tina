import 'dart:async';
import 'dart:typed_data';

import '../ansi_capable.dart';
import '../rect.dart';
import '../stdio.dart';
import '../input_latency.dart';
import 'backend_surface.dart';
import 'terminal_backend.dart';

/// ANSI escape sequence implementation of [TerminalBackend].
///
/// Batches all operations into a [StringBuffer] and writes them to
/// [Stdio] on [flush]. This matches the original Screen behavior of
/// building one batched string per operation.
class AnsiBackend implements TerminalBackend {
  final Stdio _io;
  final AnsiCapable _ansi;
  final StringBuffer _buf = StringBuffer();
  int _frameDepth = 0;
  bool _flushPending = false;

  AnsiBackend({required Stdio io, required AnsiCapable ansi})
      : _io = io,
        _ansi = ansi;

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
    _buf.write('\x1b[${row + 1};${col + 1}H');
  }

  @override
  void parkCursor(int row, int col) => moveCursor(row, col);

  @override
  void eraseCells(int row, int col, int n) {
    if (OpCounters.enabled) OpCounters.instance.gridWrites++;
    _buf.write('\x1b[${row + 1};${col + 1}H');
    _buf.write('\x1b[${n}X');
  }

  @override
  void writeText(String text) {
    if (OpCounters.enabled) OpCounters.instance.gridWrites++;
    _buf.write(text);
  }

  @override
  void saveCursor() {
    _buf.write('\x1b7');
  }

  @override
  void restoreCursor() {
    _buf.write('\x1b8');
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
      if (OpCounters.enabled) OpCounters.instance.renderCalls++;
    }
    InputLatency.stage(LatencyStage.flushCompleted);
  }

  // -- Screen lifecycle ---------------------------------------------------

  @override
  void enterAltScreen() {
    _buf.write('\x1b[?1049h');
  }

  @override
  void leaveAltScreen() {
    _buf.write('\x1b[?1049l');
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
    // The ANSI backend has no pixel-graphics protocol.  Emit a single dimmed
    // placeholder cell so the method is total and headless/CI runs degrade
    // gracefully instead of throwing.  targetSurface is ignored — ANSI has no
    // child planes, so there is no surface to parent the image onto.
    _buf.write('\x1b[${row + 1};${col + 1}H');
    _buf.write('\x1b[2m▣\x1b[0m'); // dim placeholder glyph
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
  }) {
    final r = _row(relRow);
    final c = _col(relCol);
    final clipped = clipToVisibleColumns(text, maxCols);
    if (moveCursor) {
      _backend.moveCursor(r, c);
    } else {
      _backend.saveCursor();
      _backend.moveCursor(r, c);
    }
    _backend.eraseCells(r, c, maxCols);
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
    final r = _row(relRow);
    final c = _col(relCol);
    if (!moveCursor) _backend.saveCursor();
    _backend.eraseCells(r, c, n);
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
