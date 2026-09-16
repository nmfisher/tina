/// The pure-Dart terminal emulator (tin-t8wd, plan Phase 1).
///
/// Feeds child-process bytes through a persistent VT/ANSI state machine into
/// primary/alternate grids with bounded scrollback, and answers device
/// queries. Pure Dart: no Screen, filesystem, process, or timer dependencies;
/// [feed] never writes to a terminal and never starts a process.
///
/// Parsing doctrine (plan lines 99-105): the state machine survives chunk
/// boundaries — including mid-UTF-8, mid-CSI, and mid-string — a sequence
/// caps at 4096 bytes, CSI params at 32, overflow discards through the
/// terminator, and CAN/SUB abort. Unknown completed sequences are ignored.
/// Discarded payload is never rendered as text.
library;

import 'dart:convert' show utf8;

import 'package:tina_console/src/term_width.dart' show runeWidth;

import 'terminal_state.dart';

export 'terminal_state.dart'
    show
        Cell,
        CellAttributes,
        Row,
        Scrollback,
        TerminalColor,
        TerminalGrid,
        TerminalSnapshot;

/// A local event produced by [TerminalEmulator.feed].
abstract class TerminalEvent {
  const TerminalEvent();
}

/// BEL arrived: the session wants attention, locally.
class BellEvent extends TerminalEvent {
  const BellEvent();
}

/// OSC 0/2 changed the session title (already sanitized: controls stripped).
class TitleEvent extends TerminalEvent {
  const TitleEvent(this.title);

  final String title;
}

/// What one [TerminalEmulator.feed] call produced.
class TerminalFeedResult {
  const TerminalFeedResult(this.replies, this.events);

  /// Bytes the emulator wants written back to the child (DSR/DA answers).
  final List<int> replies;

  /// Local events (bell, title) in arrival order.
  final List<TerminalEvent> events;
}

/// The terminal: bytes in, grid state and query replies out.
class TerminalEmulator {
  TerminalEmulator({
    int scrollbackMaxRows = Scrollback.defaultMaxRows,
    int scrollbackMaxCells = Scrollback.defaultMaxCells,
    int initialRows = 24,
    int initialCols = 80,
  })  : _rows = initialRows <= 0 ? 24 : initialRows,
        _cols = initialCols <= 0 ? 80 : initialCols {
    final sb = Scrollback(maxRows: scrollbackMaxRows, maxCells: scrollbackMaxCells);
    primary = TerminalGrid(rows: _rows, cols: _cols, scrollback: sb);
    alternate = TerminalGrid(rows: _rows, cols: _cols);
    _active = primary;
  }

  late TerminalGrid primary;
  late TerminalGrid alternate;
  late TerminalGrid _active;

  final int _rows;
  final int _cols;

  bool _damage = true;
  bool _inAlternate = false;

  // --- Parser state ---------------------------------------------------
  _ParserState _state = _ParserState.ground;

  // Incremental UTF-8 decode (ground-mode printing only).
  int _utf8Remaining = 0;
  int _utf8Value = 0;
  int _utf8Min = 0;

  // CSI accumulation.
  final List<int> _csiParams = <int>[];
  final List<bool> _csiSeen = <bool>[]; // digits seen for this param?
  int _csiParamIndex = 0;
  final StringBuffer _csiIntermediates = StringBuffer();

  // ESC-intermediate accumulation.
  final StringBuffer _escIntermediates = StringBuffer();

  // String accumulation (OSC/DCS/SOS/PM/APC).
  final List<int> _stringBytes = <int>[];
  bool _stringOverflow = false;
  _StringKind _stringKind = _StringKind.osc;
  int _oscCode = -1; // -1 = no numeric prefix seen yet
  bool _oscCodeEnded = false;

  /// True when anything render-relevant changed since the last takeDamage.
  bool get hasDamage => _damage;

  /// Reports and clears the damage flag.
  bool takeDamage() {
    final d = _damage;
    _damage = false;
    return d;
  }

  /// Geometry (both grids always share it).
  int get rows => primary.rows;
  int get cols => primary.cols;
  bool get inAlternateScreen => _inAlternate;

  /// Read-only snapshot of the live screen and scrollback.
  TerminalSnapshot snapshot() {
    final grid = _active;
    return TerminalSnapshot(
      rows: grid.rows,
      cols: grid.cols,
      screen: grid.screen.map(Row.copy).toList(growable: false),
      scrollback: grid.scrollback.rows,
      cursorRow: grid.cursorRow,
      cursorCol: grid.cursorCol,
      cursorVisible: grid.cursorVisible,
      primaryActive: !_inAlternate,
      screenInverse: grid.screenInverse,
    );
  }

  /// Consumes [bytes]; returns query replies and local events.
  TerminalFeedResult feed(List<int> bytes) {
    final replies = <int>[];
    final events = <TerminalEvent>[];
    _replies = replies;
    _events = events;
    for (var i = 0; i < bytes.length; i++) {
      _parse(bytes[i]);
    }
    _replies = null;
    _events = null;
    return TerminalFeedResult(replies, events);
  }

  /// Power-on state: both grids cleared, all modes off, tabs reset,
  /// scrollback cleared, parser back to ground.
  void reset() {
    primary = TerminalGrid(rows: _rows, cols: _cols, scrollback: primary.scrollback)
      ..scrollback.clear();
    alternate = TerminalGrid(rows: _rows, cols: _cols);
    _active = primary;
    _inAlternate = false;
    _resetParser();
    _damage = true;
  }

  /// Resizes both grids (crop/pad, no reflow), clamps cursors, resets
  /// margins, adds default tab stops in new columns. Never invents history.
  void resize(int newRows, int newCols) {
    if (newRows <= 0 || newCols <= 0) {
      throw ArgumentError('terminal geometry must be positive');
    }
    _resizeGrid(primary, newRows, newCols);
    _resizeGrid(alternate, newRows, newCols);
    _damage = true;
  }

  static void _resizeGrid(TerminalGrid grid, int newRows, int newCols) {
    if (grid.screen.length > newRows) {
      grid.screen.removeRange(newRows, grid.screen.length);
    }
    while (grid.screen.length < newRows) {
      grid.screen.add(Row.blank(newCols));
    }
    for (final row in grid.screen) {
      row.resizeTo(newCols);
      healRow(row, newCols);
    }
    grid.rows = newRows;
    grid.cols = newCols;
    grid.resetMargins();
    grid.addDefaultTabStops(newCols);
    if (grid.savedCursorRow >= newRows) grid.savedCursorRow = newRows - 1;
    if (grid.savedCursorCol >= newCols) grid.savedCursorCol = newCols - 1;
    if (grid.cursorRow >= newRows) grid.cursorRow = newRows - 1;
    if (grid.cursorCol >= newCols) grid.cursorCol = newCols - 1;
  }

  /// Clears continuation halves whose lead half is gone and lead halves
  /// whose continuation is gone (after erase, overwrite, or resize).
  static void healRow(Row row, int cols) {
    for (var c = 0; c < cols; c++) {
      final cell = row.cells[c];
      if (cell.isContinuation) {
        final ok = c > 0 &&
            !row.cells[c - 1].isContinuation &&
            row.cells[c - 1].text.isNotEmpty;
        if (!ok) row.cells[c] = Cell.blank;
      } else if (cell.text.isNotEmpty && _isWide(cell)) {
        final ok = c + 1 < cols && row.cells[c + 1].isContinuation;
        if (!ok) row.cells[c] = Cell.blank;
      }
    }
  }

  static bool _isWide(Cell cell) {
    final text = cell.text;
    if (text.isEmpty) return false;
    return runeWidth(text.runes.first) == 2;
  }

  void _resetParser() {
    _state = _ParserState.ground;
    _utf8Remaining = 0;
    _utf8Value = 0;
    _utf8Min = 0;
    _csiParams.clear();
    _csiSeen.clear();
    _csiParamIndex = 0;
    _csiIntermediates.clear();
    _escIntermediates.clear();
    _stringBytes.clear();
    _stringOverflow = false;
    _oscCode = -1;
    _oscCodeEnded = false;
  }

  // --- Parser core ------------------------------------------------------

  List<int>? _replies;
  List<TerminalEvent>? _events;

  void _reply(String s) {
    _replies?.addAll(utf8.encode(s));
  }

  void _event(TerminalEvent e) {
    _events?.add(e);
  }

  void _parse(int byte) {
    switch (_state) {
      case _ParserState.ground:
        _parseGround(byte);
      case _ParserState.escape:
        _parseEscape(byte);
      case _ParserState.csiEntry:
      case _ParserState.csiParam:
      case _ParserState.csiIntermediate:
      case _ParserState.csiIgnore:
        _parseCsi(byte);
      case _ParserState.oscString:
        _parseOsc(byte);
      case _ParserState.stringPassthrough:
        _parseStringPassthrough(byte);
      case _ParserState.stringEsc:
        _parseStringEsc(byte);
    }
  }

  void _parseGround(int byte) {
    if (byte < 0x20 || byte == 0x7f) {
      if (_utf8Remaining > 0) _flushMalformedUtf8();
      _executeControl(byte);
      return;
    }
    if (byte < 0x80) {
      if (_utf8Remaining > 0) _flushMalformedUtf8();
      _printCodePoint(byte);
      return;
    }
    if (_utf8Remaining == 0) {
      if (byte >= 0xc2 && byte <= 0xdf) {
        _utf8Remaining = 1;
        _utf8Value = byte & 0x1f;
        _utf8Min = 0x80;
      } else if (byte >= 0xe0 && byte <= 0xef) {
        _utf8Remaining = 2;
        _utf8Value = byte & 0x0f;
        _utf8Min = 0x800;
      } else if (byte >= 0xf0 && byte <= 0xf4) {
        _utf8Remaining = 3;
        _utf8Value = byte & 0x07;
        _utf8Min = 0x10000;
      } else {
        // 0x80-0xC1 and 0xF5-0xFF are never legal lead bytes.
        _printCodePoint(0xfffd);
      }
      return;
    }
    if (byte & 0xc0 != 0x80) {
      _flushMalformedUtf8();
      _parseGround(byte);
      return;
    }
    _utf8Value = (_utf8Value << 6) | (byte & 0x3f);
    _utf8Remaining--;
    if (_utf8Remaining == 0) {
      var cp = _utf8Value;
      if (cp < _utf8Min || (cp >= 0xd800 && cp <= 0xdfff) || cp > 0x10ffff) {
        cp = 0xfffd;
      }
      _utf8Value = 0;
      _utf8Min = 0;
      _printCodePoint(cp);
    }
  }

  void _flushMalformedUtf8() {
    _utf8Remaining = 0;
    _utf8Value = 0;
    _utf8Min = 0;
    _printCodePoint(0xfffd);
  }

  void _executeControl(int byte) {
    switch (byte) {
      case 0x07: // BEL
        _event(const BellEvent());
      case 0x08: // BS
        _active.pendingWrap = false;
        if (_active.cursorCol > 0) _active.cursorCol--;
      case 0x09: // HT
        _active.pendingWrap = false;
        _tabForward();
      case 0x0a: // LF
      case 0x0b: // VT
      case 0x0c: // FF
        _active.pendingWrap = false;
        _index();
      case 0x0d: // CR
        _active.pendingWrap = false;
        _active.cursorCol = 0;
      case 0x0e: // SO — select G1
        _active.shiftToG1 = true;
      case 0x0f: // SI — select G0
        _active.shiftToG1 = false;
      case 0x1b: // ESC
        _state = _ParserState.escape;
        _escIntermediates.clear();
      case 0x18: // CAN
      case 0x1a: // SUB
        _resetParser();
      default:
        break; // other C0 and DEL are ignored
    }
  }

  void _tabForward() {
    final grid = _active;
    var col = grid.cursorCol + 1;
    while (col < grid.cols && !grid.tabStops.contains(col)) {
      col++;
    }
    grid.cursorCol = col >= grid.cols ? grid.cols - 1 : col;
  }

  void _tabBackward() {
    final grid = _active;
    var col = grid.cursorCol - 1;
    while (col > 0 && !grid.tabStops.contains(col)) {
      col--;
    }
    grid.cursorCol = col < 0 ? 0 : col;
  }

  // --- Printing ---------------------------------------------------------

  void _printCodePoint(int cp) {
    if (runeWidth(cp) == 0) {
      _attachCombining(cp);
      return;
    }
    final grid = _active;
    if (grid.pendingWrap) {
      grid.pendingWrap = false;
      if (grid.autowrap) {
        grid.cursorCol = 0;
        _index();
      } else {
        grid.cursorCol = grid.cols - 1;
      }
    }
    if (runeWidth(cp) == 1) {
      _writeNarrow(cp);
      return;
    }
    // Wide glyph: never split across rows.
    if (grid.cursorCol == grid.cols - 1 && grid.autowrap) {
      grid.cursorCol = 0;
      _index();
    }
    final text = _mapCharset(cp);
    _placeCell(grid, grid.cursorRow, grid.cursorCol,
        Cell(text: text, attributes: grid.currentAttrs));
    final contCol = grid.cursorCol + 1;
    if (contCol < grid.cols) {
      grid.putContinuation(grid.cursorRow, contCol);
      _advance(2);
    } else {
      // DECAWM-off last column: the trailing half is clipped.
      _advance(1);
    }
  }

  void _writeNarrow(int cp) {
    final grid = _active;
    _placeCell(grid, grid.cursorRow, grid.cursorCol,
        Cell(text: _mapCharset(cp), attributes: grid.currentAttrs));
    _advance(1);
  }

  /// DEC Special Graphics translation for the active character set.
  String _mapCharset(int cp) {
    final set = _active.shiftToG1 ? _active.g1Charset : _active.g0Charset;
    if (set != 1) return String.fromCharCode(cp);
    if (cp < 0x60 || cp > 0x7e) return String.fromCharCode(cp);
    return String.fromCharCode(_decGraphics[cp - 0x60]);
  }

  static const List<int> _decGraphics = <int>[
    0x25c6, 0x2592, 0x2409, 0x240c, 0x240d, 0x240e, 0x00b0, 0x00b1, //
    0x2424, 0x240b, 0x2518, 0x2510, 0x2514, 0x251c, 0x2500, 0x2502,
    0x250c, 0x250c, 0x250c, 0x250c, 0x250c, 0x2560, 0x2554, 0x2557,
    0x2554, 0x2554, 0x2554, 0x2554, 0x2554, 0x255d, 0x255a, 0x2554,
    0x2554, 0x2554, 0x2554, 0x2554, 0x2554, 0x2554, 0x2554, 0x2554,
    0x2554, 0x2500, 0x2500, 0x2500, 0x2500, 0x2500, 0x2500, 0x2500,
    0x2500, 0x2500, 0x2553, 0x2556, 0x255c, 0x255f, 0x2562, 0x255a,
    0x2554, 0x2554, 0x2554, 0x2554, 0x2554, 0x2554, 0x2554, 0x2554,
    0x2554, 0x2554, 0x2554, 0x2554, 0x2554, 0x2554, 0x2554, 0x2554,
    0x2554, 0x2563, 0x2566, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560,
    0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2550, 0x2550, 0x2550,
    0x2550, 0x256c, 0x2569, 0x2564, 0x2564, 0x2564, 0x2564, 0x2564,
    0x2564, 0x2564, 0x2564, 0x2564, 0x2564, 0x2564, 0x2564, 0x2564,
    0x2564, 0x2564, 0x2564, 0x2553, 0x2553, 0x2553, 0x2553, 0x2553,
    0x2553, 0x2553, 0x2553, 0x2553, 0x2553, 0x2553, 0x2553, 0x2553,
    0x2553, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560,
    0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560,
    0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560,
    0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560,
    0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560,
    0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560,
    0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560,
    0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560,
    0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560,
    0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560,
    0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560,
    0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560,
    0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560,
    0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560,
    0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560,
    0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560,
    0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560,
    0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560,
    0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560, 0x2560,
    0x2560,
  ];

  void _attachCombining(int cp) {
    final grid = _active;
    final row = grid.cursorRow;
    int col;
    if (grid.pendingWrap) {
      col = grid.cursorCol; // attach to the last written cell
    } else {
      if (grid.cursorCol == 0) return; // no base cell
      col = grid.cursorCol - 1;
    }
    final cells = grid.screen[row].cells;
    final base = cells[col];
    if (base.isContinuation) return;
    cells[col] = base.withCombining(String.fromCharCode(cp), grid.currentAttrs);
    _damage = true;
  }

  void _placeCell(TerminalGrid grid, int row, int col, Cell cell) {
    if (grid.insertMode) {
      _insertCells(1);
    }
    grid.putCell(row, col, cell);
    _damage = true;
  }

  void _advance(int n) {
    final grid = _active;
    if (grid.cursorCol + n >= grid.cols) {
      grid.cursorCol = grid.cols - 1;
      if (grid.autowrap) grid.pendingWrap = true;
    } else {
      grid.cursorCol += n;
    }
  }

  // --- Line/region mechanics --------------------------------------------

  void _index() {
    final grid = _active;
    final bottom = grid.effectiveBottom;
    if (grid.cursorRow == bottom) {
      _scrollUp(1);
    } else if (grid.cursorRow < grid.rows - 1) {
      grid.cursorRow++;
    }
  }

  void _reverseIndex() {
    final grid = _active;
    final top = grid.effectiveTop;
    if (grid.cursorRow == top) {
      _scrollDown(1);
    } else if (grid.cursorRow > 0) {
      grid.cursorRow--;
    }
  }

  void _scrollUp(int n) {
    final grid = _active;
    final top = grid.effectiveTop;
    final bottom = grid.effectiveBottom;
    if (bottom <= top) return;
    final count = n.clamp(1, bottom - top + 1);
    final historyEligible =
        identical(grid, primary) && top == 0 && bottom == grid.rows - 1;
    for (var i = 0; i < count; i++) {
      final removed = grid.screen[top];
      if (historyEligible && !removed.isBlank) {
        grid.scrollback.push(removed);
      }
      for (var r = top; r < bottom; r++) {
        grid.screen[r] = grid.screen[r + 1];
      }
      grid.screen[bottom] = Row.blank(grid.cols);
    }
    _damage = true;
  }

  void _scrollDown(int n) {
    final grid = _active;
    final top = grid.effectiveTop;
    final bottom = grid.effectiveBottom;
    if (bottom <= top) return;
    final count = n.clamp(1, bottom - top + 1);
    for (var i = 0; i < count; i++) {
      for (var r = bottom; r > top; r--) {
        grid.screen[r] = grid.screen[r - 1];
      }
      grid.screen[top] = Row.blank(grid.cols);
    }
    _damage = true;
  }

  void _insertLines(int n) {
    final grid = _active;
    if (!_insideMargins) return;
    final bottom = grid.effectiveBottom;
    final count = n.clamp(1, bottom - grid.cursorRow + 1);
    for (var i = 0; i < count; i++) {
      for (var r = bottom; r > grid.cursorRow; r--) {
        grid.screen[r] = grid.screen[r - 1];
      }
      grid.screen[grid.cursorRow] = Row.blank(grid.cols);
    }
    grid.pendingWrap = false;
    _damage = true;
  }

  void _deleteLines(int n) {
    final grid = _active;
    if (!_insideMargins) return;
    final bottom = grid.effectiveBottom;
    final count = n.clamp(1, bottom - grid.cursorRow + 1);
    for (var i = 0; i < count; i++) {
      for (var r = grid.cursorRow; r < bottom; r++) {
        grid.screen[r] = grid.screen[r + 1];
      }
      grid.screen[bottom] = Row.blank(grid.cols);
    }
    grid.pendingWrap = false;
    _damage = true;
  }

  bool get _insideMargins {
    final grid = _active;
    return grid.cursorRow >= grid.effectiveTop &&
        grid.cursorRow <= grid.effectiveBottom;
  }

  void _insertCells(int n) {
    final grid = _active;
    final row = grid.screen[grid.cursorRow];
    final cells = row.cells;
    final col = grid.cursorCol;
    for (var i = 0; i < n && col < cells.length; i++) {
      cells.insert(col, Cell.blank);
      cells.removeLast();
    }
    healRow(row, grid.cols);
    _damage = true;
  }

  void _deleteCells(int n) {
    final grid = _active;
    final row = grid.screen[grid.cursorRow];
    final cells = row.cells;
    final col = grid.cursorCol;
    for (var i = 0; i < n && col < cells.length; i++) {
      cells.removeAt(col);
      cells.add(Cell.blank);
    }
    healRow(row, grid.cols);
    _damage = true;
  }

  void _eraseCells(int n) {
    final grid = _active;
    final end = (grid.cursorCol + n).clamp(0, grid.cols);
    for (var c = grid.cursorCol; c < end; c++) {
      grid.putCell(grid.cursorRow, c, _blankCell());
    }
    healRow(grid.screen[grid.cursorRow], grid.cols);
    _damage = true;
  }

  Cell _blankCell() {
    final attrs = _active.currentAttrs;
    return attrs == CellAttributes.plain
        ? Cell.blank
        : Cell(text: '', attributes: attrs);
  }

  // --- ESC sequences ------------------------------------------------------

  void _parseEscape(int byte) {
    if (byte == 0x1b) {
      _escIntermediates.clear();
      return; // stay in escape
    }
    if (byte < 0x20) {
      _executeControl(byte);
      return;
    }
    if (byte >= 0x20 && byte <= 0x2f) {
      _escIntermediates.writeCharCode(byte);
      return;
    }
    if (byte >= 0x30 && byte <= 0x7e) {
      _dispatchEscape(byte);
      return;
    }
    _state = _ParserState.ground; // DEL / 0x80+: abandon
  }

  void _dispatchEscape(int byte) {
    _state = _ParserState.ground;
    final inter = _escIntermediates.toString();
    if (inter == '#') {
      if (byte == 0x38) _alignmentPattern(); // ESC # 8 — DECALN
      _escIntermediates.clear();
      return;
    }
    switch (inter) {
      case '':
        break;
      case '(':
        _designateCharset(0, byte);
        return;
      case ')':
        _designateCharset(1, byte);
        return;
      default:
        _escIntermediates.clear();
        return; // unknown intermediate sequence — ignored
    }
    switch (byte) {
      case 0x44: // IND
        _active.pendingWrap = false;
        _index();
      case 0x45: // NEL
        _active.pendingWrap = false;
        _active.cursorCol = 0;
        _index();
      case 0x4d: // RI
        _active.pendingWrap = false;
        _reverseIndex();
      case 0x48: // HTS
        _active.tabStops.add(_active.cursorCol);
      case 0x37: // DECSC
        _saveCursor();
      case 0x38: // DECRC
        _restoreCursor();
      case 0x3d: // application keypad
        _active.applicationKeypad = true;
      case 0x3e: // numeric keypad
        _active.applicationKeypad = false;
      case 0x63: // RIS
        reset();
      case 0x5d: // OSC
        _startString(_StringKind.osc);
      case 0x50: // DCS
        _startString(_StringKind.dcs);
      case 0x58: // SOS
      case 0x5e: // PM
      case 0x5f: // APC
        _startString(_StringKind.other);
      default:
        break; // unknown — ignored
    }
  }

  void _alignmentPattern() {
    final grid = _active;
    for (var r = 0; r < grid.rows; r++) {
      final row = Row.blank(grid.cols);
      for (var c = 0; c < grid.cols; c++) {
        row.cells[c] = const Cell(text: 'E');
      }
      grid.screen[r] = row;
    }
    grid.resetMargins();
    grid.cursorRow = 0;
    grid.cursorCol = 0;
    _damage = true;
  }

  void _designateCharset(int slot, int byte) {
    // 'B' = ASCII, '0' = DEC Special Graphics; everything else ignored.
    final value = byte == 0x30 ? 1 : 0;
    if (slot == 0) {
      _active.g0Charset = value;
    } else {
      _active.g1Charset = value;
    }
  }

  void _saveCursor() {
    final grid = _active;
    grid.savedCursorRow = grid.cursorRow;
    grid.savedCursorCol = grid.cursorCol;
    grid.savedAttrs = grid.currentAttrs;
    grid.savedOriginMode = grid.originMode;
    grid.savedPendingWrap = grid.pendingWrap;
    grid.savedG0 = grid.g0Charset;
    grid.savedG1 = grid.g1Charset;
    grid.savedShift = grid.shiftToG1;
  }

  void _restoreCursor() {
    final grid = _active;
    grid.cursorRow = grid.savedCursorRow.clamp(0, grid.rows - 1);
    grid.cursorCol = grid.savedCursorCol.clamp(0, grid.cols - 1);
    grid.currentAttrs = grid.savedAttrs;
    grid.originMode = grid.savedOriginMode;
    grid.pendingWrap = grid.savedPendingWrap;
    grid.g0Charset = grid.savedG0;
    grid.g1Charset = grid.savedG1;
    grid.shiftToG1 = grid.savedShift;
  }

  // --- Strings (OSC/DCS/SOS/PM/APC) ----------------------------------------

  void _startString(_StringKind kind) {
    _stringKind = kind;
    _stringBytes.clear();
    _stringOverflow = false;
    _oscCode = -1;
    _oscCodeEnded = false;
    _state = kind == _StringKind.osc
        ? _ParserState.oscString
        : _ParserState.stringPassthrough;
  }

  void _parseOsc(int byte) {
    if (byte == 0x07) {
      _finishOsc();
      return;
    }
    if (byte == 0x1b) {
      _state = _ParserState.stringEsc;
      return;
    }
    if (byte < 0x20) {
      return; // ignored control inside OSC
    }
    if (_stringBytes.length >= maxSequenceBytes) {
      _stringOverflow = true;
      return;
    }
    _stringBytes.add(byte);
    if (!_oscCodeEnded) {
      if (byte >= 0x30 && byte <= 0x39) {
        if (_oscCode < 0) _oscCode = 0;
        _oscCode = _oscCode * 10 + (byte - 0x30);
      } else if (byte == 0x3b) {
        _oscCodeEnded = true;
      } else {
        _oscCode = -2; // non-numeric prefix (query etc.) — no local action
        _oscCodeEnded = true;
      }
    }
  }

  void _finishOsc() {
    _state = _ParserState.ground;
    if (_stringOverflow || _oscCode != 0 && _oscCode != 2) return;
    final title = _sanitizeTitle(_decodeStringPayload());
    if (title.isNotEmpty) _event(TitleEvent(title));
    // OSC 52 (clipboard), 8 (hyperlinks), 1337, ... — deliberately no effect.
  }

  String _decodeStringPayload() {
    if (_stringBytes.isEmpty) return '';
    var start = 0;
    while (start < _stringBytes.length && _stringBytes[start] != 0x3b) {
      start++;
    }
    if (start < _stringBytes.length) start++;
    return utf8.decode(_stringBytes.sublist(start), allowMalformed: true);
  }

  String _sanitizeTitle(String raw) {
    final buf = StringBuffer();
    for (final rune in raw.runes) {
      if (rune == 0x1b) continue;
      if (rune < 0x20 || (rune >= 0x7f && rune < 0xa0)) {
        buf.write(' ');
      } else {
        buf.writeCharCode(rune);
      }
    }
    return buf.toString();
  }

  void _parseStringPassthrough(int byte) {
    if (byte == 0x1b) {
      _state = _ParserState.stringEsc;
      return;
    }
    if (byte == 0x9c) {
      _state = _ParserState.ground;
      return;
    }
    // Payload dropped (bounded by the ESC check above; raw length is capped
    // implicitly because every byte passes through without storage).
  }

  void _parseStringEsc(int byte) {
    if (byte == 0x5c) {
      // ST
      if (_stringKind == _StringKind.osc) {
        _finishOsc();
      } else {
        _state = _ParserState.ground;
      }
      return;
    }
    _state = _ParserState.escape;
    _escIntermediates.clear();
    _parseEscape(byte);
  }

  // --- CSI -------------------------------------------------------------------

  void _parseCsi(int byte) {
    if (byte == 0x1b) {
      _state = _ParserState.escape;
      _escIntermediates.clear();
      return;
    }
    if (byte == 0x18 || byte == 0x1a) {
      _resetParser(); // CAN/SUB abort the sequence
      return;
    }
    if (byte < 0x20) {
      _executeControl(byte);
      return;
    }
    if (_state == _ParserState.csiIgnore) {
      if (byte >= 0x40 && byte <= 0x7e) _state = _ParserState.ground;
      return;
    }
    if (byte >= 0x30 && byte <= 0x39) {
      _state = _ParserState.csiParam;
      _paramDigit(byte - 0x30);
      return;
    }
    if (byte == 0x3a) {
      _state = _ParserState.csiParam;
      return; // sub-parameter separator: folded into the current param
    }
    if (byte == 0x3b) {
      _state = _ParserState.csiParam;
      _paramSeparator();
      return;
    }
    if (byte >= 0x20 && byte <= 0x2f) {
      _state = _ParserState.csiIntermediate;
      _csiIntermediates.writeCharCode(byte);
      return;
    }
    if (byte >= 0x40 && byte <= 0x7e) {
      _dispatchCsi(byte);
      return;
    }
    _state = _ParserState.csiIgnore; // stray byte: skip to final
  }

  void _paramDigit(int digit) {
    if (_csiParamIndex >= maxCsiParams) {
      _state = _ParserState.csiIgnore;
      return;
    }
    if (_csiParamIndex == _csiParams.length) {
      _csiParams.add(0);
      _csiSeen.add(false);
    }
    _csiParams[_csiParamIndex] = _csiParams[_csiParamIndex] * 10 + digit;
    _csiSeen[_csiParamIndex] = true;
  }

  void _paramSeparator() {
    if (_csiParamIndex >= maxCsiParams) {
      _state = _ParserState.csiIgnore;
      return;
    }
    if (_csiParamIndex == _csiParams.length) {
      _csiParams.add(0);
      _csiSeen.add(false);
    }
    _csiParamIndex++;
  }

  int _param(int index, int fallback) {
    if (index >= _csiParams.length) return fallback;
    if (!_csiSeen[index]) return fallback;
    return _csiParams[index];
  }

  int _paramOrZero(int index) {
    if (index >= _csiParams.length) return 0;
    return _csiParams[index];
  }

  void _dispatchCsi(int byte) {
    _state = _ParserState.ground;
    final grid = _active;
    final inter = _csiIntermediates.toString();
    _csiIntermediates.clear();
    final private = inter == '?' || inter == '>' || inter == '<' || inter == '=';
    if (inter.isNotEmpty && !private) {
      return; // intermediate-marked (e.g. CSI ! p) — not implemented
    }
    final n1 = _param(0, 1);
    final n2 = _param(1, 1);

    if (inter == '>') {
      if (byte == 0x63) _reply('\x1b[>0;10;1c'); // secondary DA
      return;
    }
    if (inter == '?') {
      switch (byte) {
        case 0x68:
          _decSet(true);
        case 0x6c:
          _decSet(false);
        case 0x6e: // DECXCPR
          if (_paramOrZero(0) == 6) _replyCpr(prefixed: true);
        default:
          break;
      }
      return;
    }

    switch (byte) {
      case 0x40: // ICH
        _insertCells(n1);
      case 0x41: // CUU
        _moveVertical(-n1);
      case 0x42: // CUD
        _moveVertical(n1);
      case 0x43: // CUF
        grid.pendingWrap = false;
        grid.cursorCol = (grid.cursorCol + n1).clamp(0, grid.cols - 1);
      case 0x44: // CUB
        grid.pendingWrap = false;
        grid.cursorCol = (grid.cursorCol - n1).clamp(0, grid.cols - 1);
      case 0x45: // CNL
        _moveVertical(n1);
        grid.cursorCol = 0;
      case 0x46: // CPL
        _moveVertical(-n1);
        grid.cursorCol = 0;
      case 0x47: // CHA
        grid.pendingWrap = false;
        grid.cursorCol = (n1 - 1).clamp(0, grid.cols - 1);
      case 0x48: // CUP
      case 0x66: // HVP
        _setPosition(n1, n2);
      case 0x64: // VPA
        _setRow(n1);
      case 0x4a: // ED
        _eraseDisplay(_paramOrZero(0));
      case 0x4b: // EL
        _eraseLine(_paramOrZero(0));
      case 0x50: // DCH
        _deleteCells(n1);
      case 0x58: // ECH
        _eraseCells(n1);
      case 0x4c: // IL
        _insertLines(n1);
      case 0x4d: // DL
        _deleteLines(n1);
      case 0x53: // SU
        _scrollUp(n1);
      case 0x54: // SD
        _scrollDown(n1);
      case 0x72: // DECSTBM
        _setMargins(n1, n2);
      case 0x68: // SM
        if (_paramOrZero(0) == 4) grid.insertMode = true;
      case 0x6c: // RM
        if (_paramOrZero(0) == 4) grid.insertMode = false;
      case 0x6d: // SGR
        _sgr();
      case 0x6e: // DSR
        _dsr(_paramOrZero(0));
      case 0x63: // DA1
        _reply('\x1b[?62;22c');
      case 0x67: // TBC
        _tabClear(_paramOrZero(0));
      case 0x73: // SCOSC
        _saveCursor();
      case 0x75: // SCORC
        _restoreCursor();
      case 0x5a: // CBT
        for (var i = 0; i < n1; i++) {
          _tabBackward();
        }
      default:
        break; // unknown final — ignored
    }
  }

  void _moveVertical(int delta) {
    final grid = _active;
    grid.pendingWrap = false;
    final top = grid.effectiveTop;
    final bottom = grid.effectiveBottom;
    final target = grid.cursorRow + delta;
    if (grid.cursorRow >= top && grid.cursorRow <= bottom) {
      grid.cursorRow = target.clamp(top, bottom);
    } else {
      grid.cursorRow = target.clamp(0, grid.rows - 1);
    }
  }

  void _setPosition(int rowParam, int colParam) {
    final grid = _active;
    grid.pendingWrap = false;
    grid.cursorRow = _resolveRow(rowParam - 1);
    grid.cursorCol = (colParam - 1).clamp(0, grid.cols - 1);
  }

  void _setRow(int rowParam) {
    final grid = _active;
    grid.pendingWrap = false;
    grid.cursorRow = _resolveRow(rowParam - 1);
  }

  int _resolveRow(int zeroBased) {
    final grid = _active;
    if (grid.originMode) {
      return (grid.effectiveTop + zeroBased)
          .clamp(grid.effectiveTop, grid.effectiveBottom);
    }
    return zeroBased.clamp(0, grid.rows - 1);
  }

  void _setMargins(int topParam, int bottomParam) {
    final grid = _active;
    final top = topParam - 1;
    final bottom = bottomParam - 1;
    if (top < 0 || bottom >= grid.rows || top >= bottom) return;
    grid.marginTop = top;
    grid.marginBottom = bottom;
    grid.pendingWrap = false;
    grid.cursorRow = grid.originMode ? top : 0;
    grid.cursorCol = 0;
  }

  void _eraseDisplay(int mode) {
    final grid = _active;
    switch (mode) {
      case 0:
        _eraseRowRange(grid.cursorRow, grid.cursorCol, grid.cols - 1);
        for (var r = grid.cursorRow + 1; r < grid.rows; r++) {
          grid.screen[r] = Row.blank(grid.cols);
        }
      case 1:
        for (var r = 0; r < grid.cursorRow; r++) {
          grid.screen[r] = Row.blank(grid.cols);
        }
        _eraseRowRange(grid.cursorRow, 0, grid.cursorCol);
      case 2:
        for (var r = 0; r < grid.rows; r++) {
          grid.screen[r] = Row.blank(grid.cols);
        }
      case 3:
        for (var r = 0; r < grid.rows; r++) {
          grid.screen[r] = Row.blank(grid.cols);
        }
        if (!_inAlternate) grid.scrollback.clear();
      default:
        break;
    }
    _damage = true;
  }

  void _eraseRowRange(int row, int from, int to) {
    final grid = _active;
    for (var c = from; c <= to; c++) {
      grid.putCell(row, c, _blankCell());
    }
    healRow(grid.screen[row], grid.cols);
  }

  void _eraseLine(int mode) {
    final grid = _active;
    switch (mode) {
      case 0:
        _eraseRowRange(grid.cursorRow, grid.cursorCol, grid.cols - 1);
      case 1:
        _eraseRowRange(grid.cursorRow, 0, grid.cursorCol);
      case 2:
        _eraseRowRange(grid.cursorRow, 0, grid.cols - 1);
      default:
        break;
    }
    _damage = true;
  }

  void _tabClear(int mode) {
    final grid = _active;
    switch (mode) {
      case 0:
        grid.tabStops.remove(grid.cursorCol);
      case 2:
      case 3:
        grid.tabStops.clear();
      default:
        break;
    }
  }

  void _dsr(int mode) {
    switch (mode) {
      case 5:
        _reply('\x1b[0n');
      case 6:
        _replyCpr(prefixed: false);
      default:
        break;
    }
  }

  void _replyCpr({required bool prefixed}) {
    final grid = _active;
    var row = grid.cursorRow;
    if (grid.originMode) row -= grid.effectiveTop;
    final prefix = prefixed ? '?' : '';
    _reply('\x1b[$prefix${row + 1};${grid.cursorCol + 1}R');
  }

  void _decSet(bool on) {
    final grid = _active;
    for (var i = 0; i < _csiParams.length; i++) {
      switch (_csiParams[i]) {
        case 1: // DECCKM
          grid.applicationCursorKeys = on;
        case 5: // DECSCNM
          grid.screenInverse = on;
        case 6: // DECOM
          grid.originMode = on;
          grid.pendingWrap = false;
          grid.cursorRow = on ? grid.effectiveTop : 0;
          grid.cursorCol = 0;
        case 7: // DECAWM
          grid.autowrap = on;
          grid.pendingWrap = false;
        case 25: // DECTCEM
          grid.cursorVisible = on;
        case 47:
          _switchScreen(toAlt: on);
        case 1047:
          // xterm clears the alternate screen when leaving it.
          if (on) {
            _switchScreen(toAlt: true);
          } else {
            _clearAlternate();
            _switchScreen(toAlt: false);
          }
        case 1048:
          if (on) {
            _saveCursor();
          } else {
            _restoreCursor();
          }
        case 1049:
          // xterm clears the alternate screen when entering it.
          if (on) {
            _saveCursor();
            _switchScreen(toAlt: true);
            _clearAlternate();
          } else {
            _switchScreen(toAlt: false);
            _restoreCursor();
          }
        case 2004:
          grid.bracketedPaste = on;
        case 1004:
          grid.focusReporting = on;
        default:
          break; // unknown private mode — ignored
      }
    }
    _damage = true;
  }

  void _switchScreen({required bool toAlt}) {
    if (toAlt) {
      _inAlternate = true;
      _active = alternate;
    } else {
      _inAlternate = false;
      _active = primary;
    }
    _damage = true;
  }

  void _clearAlternate() {
    for (var r = 0; r < alternate.rows; r++) {
      alternate.screen[r] = Row.blank(alternate.cols);
    }
    _damage = true;
  }

  // --- SGR ---------------------------------------------------------------------

  void _sgr() {
    final grid = _active;
    var attrs = grid.currentAttrs;
    if (_csiParams.isEmpty) {
      grid.currentAttrs = CellAttributes.plain;
      _damage = true;
      return;
    }
    var i = 0;
    while (i < _csiParams.length) {
      final p = _csiParams[i];
      switch (p) {
        case 0:
          attrs = CellAttributes.plain;
        case 1:
          attrs = attrs.withBold();
        case 2:
          attrs = attrs.withFaint();
        case 3:
          attrs = attrs.withItalic();
        case 4:
          attrs = attrs.withUnderline();
        case 5:
          attrs = attrs.withBlink();
        case 7:
          attrs = attrs.withInverse();
        case 8:
          attrs = attrs.withInvisible();
        case 9:
          attrs = attrs.withStrikethrough();
        case 22:
          attrs = attrs.withoutBoldFaint();
        case 23:
          attrs = attrs.withoutItalic();
        case 24:
          attrs = attrs.withoutUnderline();
        case 25:
          attrs = attrs.withoutBlink();
        case 27:
          attrs = attrs.withoutInverse();
        case 28:
          attrs = attrs.withoutInvisible();
        case 29:
          attrs = attrs.withoutStrikethrough();
        case 30:
        case 31:
        case 32:
        case 33:
        case 34:
        case 35:
        case 36:
        case 37:
          attrs = attrs.withFg(TerminalColor.indexed(p - 30));
        case 38:
        case 48:
          final ext = _extendedColor(i, attrs, setFg: p == 38);
          attrs = ext.$1;
          i += ext.$2;
        case 39:
          attrs = attrs.withDefaultFg();
        case 40:
        case 41:
        case 42:
        case 43:
        case 44:
        case 45:
        case 46:
        case 47:
          attrs = attrs.withBg(TerminalColor.indexed(p - 40));
        case 49:
          attrs = attrs.withDefaultBg();
        case 90:
        case 91:
        case 92:
        case 93:
        case 94:
        case 95:
        case 96:
        case 97:
          attrs = attrs.withFg(TerminalColor.indexed(p - 90 + 8));
        case 100:
        case 101:
        case 102:
        case 103:
        case 104:
        case 105:
        case 106:
        case 107:
          attrs = attrs.withBg(TerminalColor.indexed(p - 100 + 8));
        default:
          break; // unknown SGR — ignored
      }
      i++;
    }
    grid.currentAttrs = attrs;
    _damage = true;
  }

  /// Extended colour (SGR 38/48): returns the new attributes and how many
  /// parameters the colour consumed (including the 38/48 marker).
  (CellAttributes, int) _extendedColor(
      int index, CellAttributes attrs,
      {required bool setFg}) {
    if (index + 1 >= _csiParams.length) return (attrs, 1);
    final kind = _csiParams[index + 1];
    if (kind == 5 && index + 2 < _csiParams.length) {
      final color =
          TerminalColor.indexed(_csiParams[index + 2].clamp(0, 255));
      return (setFg ? attrs.withFg(color) : attrs.withBg(color), 3);
    }
    if (kind == 2 && index + 4 < _csiParams.length) {
      final r = _csiParams[index + 2].clamp(0, 255);
      final g = _csiParams[index + 3].clamp(0, 255);
      final b = _csiParams[index + 4].clamp(0, 255);
      final color = TerminalColor.rgb((r << 16) | (g << 8) | b);
      return (setFg ? attrs.withFg(color) : attrs.withBg(color), 5);
    }
    return (attrs, 1); // malformed — ignored
  }

  // --- Limits --------------------------------------------------------------------

  /// Maximum bytes accumulated for one string sequence before its payload
  /// is discarded (through the terminator).
  static const int maxSequenceBytes = 4096;

  /// Maximum CSI parameters before the rest of the sequence is discarded.
  static const int maxCsiParams = 32;
}

enum _ParserState {
  ground,
  escape,
  csiEntry,
  csiParam,
  csiIntermediate,
  csiIgnore,
  oscString,
  stringPassthrough,
  stringEsc,
}

enum _StringKind { osc, dcs, other }
