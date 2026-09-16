/// State types for the pure-Dart terminal emulator (tin-t8wd, plan Phase 1).
///
/// Deliberately dependency-free: no Screen, no filesystem, no process, no
/// timers, no package imports. The emulator owns all mutation; these types
/// are data plus the small kernels that belong to the state itself.
///
/// Width doctrine: cells follow the console's `runeWidth` conventions as
/// seen by the emulator (`packages/tina_console/lib/src/term_width.dart`) —
/// a wide glyph occupies two cells (second half a zero-length continuation),
/// combining marks advance nothing and are capped per cell.
library;

/// Attributes of one terminal cell (the SGR state when it was written).
class CellAttributes {
  /// Power-on attributes (SGR 0).
  const CellAttributes({
    this.bold = false,
    this.faint = false,
    this.italic = false,
    this.underline = false,
    this.blink = false,
    this.inverse = false,
    this.invisible = false,
    this.strikethrough = false,
    this.fg,
    this.bg,
  });

  static const CellAttributes plain = CellAttributes();

  final bool bold;
  final bool faint;
  final bool italic;
  final bool underline;
  final bool blink;
  final bool inverse;
  final bool invisible;
  final bool strikethrough;

  /// Foreground colour, or null for the terminal default.
  final TerminalColor? fg;

  /// Background colour, or null for the terminal default.
  final TerminalColor? bg;

  bool get isPlain =>
      !bold &&
      !faint &&
      !italic &&
      !underline &&
      !blink &&
      !inverse &&
      !invisible &&
      !strikethrough &&
      fg == null &&
      bg == null;

  CellAttributes withBold() => CellAttributes(
        bold: true,
        faint: faint,
        italic: italic,
        underline: underline,
        blink: blink,
        inverse: inverse,
        invisible: invisible,
        strikethrough: strikethrough,
        fg: fg,
        bg: bg,
      );

  CellAttributes withFaint() => _with(faint: true);

  CellAttributes withItalic() => _with(italic: true);

  CellAttributes withUnderline() => _with(underline: true);

  CellAttributes withBlink() => _with(blink: true);

  CellAttributes withInverse() => _with(inverse: true);

  CellAttributes withInvisible() => _with(invisible: true);

  CellAttributes withStrikethrough() => _with(strikethrough: true);

  /// SGR 22 — clears bold and faint together.
  CellAttributes withoutBoldFaint() => _with(bold: false, faint: false);

  /// SGR 23.
  CellAttributes withoutItalic() => _with(italic: false);

  /// SGR 24.
  CellAttributes withoutUnderline() => _with(underline: false);

  /// SGR 25.
  CellAttributes withoutBlink() => _with(blink: false);

  /// SGR 27.
  CellAttributes withoutInverse() => _with(inverse: false);

  /// SGR 28.
  CellAttributes withoutInvisible() => _with(invisible: false);

  /// SGR 29.
  CellAttributes withoutStrikethrough() => _with(strikethrough: false);

  /// SGR 39.
  CellAttributes withDefaultFg() => _with(fg: null);

  /// SGR 49.
  CellAttributes withDefaultBg() => _with(bg: null);

  CellAttributes withFg(TerminalColor? color) => _with(fg: color);

  CellAttributes withBg(TerminalColor? color) => _with(bg: color);

  CellAttributes _with({
    bool? bold,
    bool? faint,
    bool? italic,
    bool? underline,
    bool? blink,
    bool? inverse,
    bool? invisible,
    bool? strikethrough,
    Object? fg = _sentinel,
    Object? bg = _sentinel,
  }) => CellAttributes(
        bold: bold ?? this.bold,
        faint: faint ?? this.faint,
        italic: italic ?? this.italic,
        underline: underline ?? this.underline,
        blink: blink ?? this.blink,
        inverse: inverse ?? this.inverse,
        invisible: invisible ?? this.invisible,
        strikethrough: strikethrough ?? this.strikethrough,
        fg: fg == _sentinel ? this.fg : fg as TerminalColor?,
        bg: bg == _sentinel ? this.bg : bg as TerminalColor?,
      );

  static const Object _sentinel = Object();

  @override
  bool operator ==(Object other) =>
      other is CellAttributes &&
      other.bold == bold &&
      other.faint == faint &&
      other.italic == italic &&
      other.underline == underline &&
      other.blink == blink &&
      other.inverse == inverse &&
      other.invisible == invisible &&
      other.strikethrough == strikethrough &&
      other.fg == fg &&
      other.bg == bg;

  @override
  int get hashCode => Object.hash(bold, faint, italic, underline, blink,
      inverse, invisible, strikethrough, fg, bg);

  @override
  String toString() => 'CellAttributes('
      '${bold ? 'bold ' : ''}${faint ? 'faint ' : ''}'
      '${italic ? 'italic ' : ''}${underline ? 'ul ' : ''}'
      '${blink ? 'blink ' : ''}${inverse ? 'inv ' : ''}'
      '${invisible ? 'hidden ' : ''}${strikethrough ? 'strike ' : ''}'
      'fg=$fg bg=$bg)';
}

/// A terminal colour: 256-cell palette index or direct RGB.
class TerminalColor {
  const TerminalColor.indexed(this.index) : rgb = null;

  const TerminalColor.rgb(this.rgb) : index = null;

  /// 0-255, or null when [rgb] is set.
  final int? index;

  /// `0xRRGGBB`, or null when [index] is set.
  final int? rgb;

  @override
  bool operator ==(Object other) =>
      other is TerminalColor && other.index == index && other.rgb == rgb;

  @override
  int get hashCode => Object.hash(index, rgb);

  @override
  String toString() =>
      index != null ? 'color($index)' : 'rgb(${rgb!.toRadixString(16)})';
}

/// One terminal cell: a grapheme cluster, its width marker, and attributes.
///
/// A wide glyph's lead half holds [text]; the trailing half is a dedicated
/// continuation cell ([isContinuation], empty text). Combining marks join
/// the lead cell's [combining] list, capped at [maxCombining].
class Cell {
  const Cell({
    this.text = '',
    this.isContinuation = false,
    this.combining = const <String>[],
    this.attributes = CellAttributes.plain,
  });

  /// Maximum combining marks stored per cell; further marks replace the
  /// last stored mark so one cell can never grow without end.
  static const int maxCombining = 64;

  /// The blank with default attributes.
  static const Cell blank = Cell();

  /// The base grapheme (empty for blanks and continuation halves).
  final String text;

  /// True for the trailing half of a double-width glyph.
  final bool isContinuation;

  /// Combining marks attached to [text], in arrival order.
  final List<String> combining;

  final CellAttributes attributes;

  bool get isBlank =>
      text.isEmpty && combining.isEmpty && !isContinuation && attributes.isPlain;

  /// Cell with [mark] appended (respecting [maxCombining]) and [attrs].
  Cell withCombining(String mark, CellAttributes attrs) {
    final next = List<String>.of(combining);
    if (next.length >= maxCombining) {
      next[next.length - 1] = mark;
    } else {
      next.add(mark);
    }
    return Cell(
      text: text,
      isContinuation: isContinuation,
      combining: next,
      attributes: attrs,
    );
  }

  /// The full cluster string (base plus combining marks).
  String get cluster {
    final buf = StringBuffer()..write(text);
    for (final mark in combining) {
      buf.write(mark);
    }
    return buf.toString();
  }

  @override
  bool operator ==(Object other) =>
      other is Cell &&
      other.text == text &&
      other.isContinuation == isContinuation &&
      _listsEqual(other.combining, combining) &&
      other.attributes == attributes;

  @override
  int get hashCode => Object.hash(text, isContinuation, attributes);

  static bool _listsEqual(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// One screen or scrollback row; [cells] length always equals grid width.
class Row {
  Row.blank(int width)
      : cells = List<Cell>.filled(width, Cell.blank);

  Row._(this.cells);

  /// Deep-ish copy: cells are immutable-in-practice, the list is not.
  factory Row.copy(Row other) => Row._(List<Cell>.of(other.cells));

  final List<Cell> cells;

  int get width => cells.length;

  /// Grows or shrinks to [width], padding with blanks at the tail.
  void resizeTo(int width) {
    if (width == cells.length) return;
    if (width < cells.length) {
      cells.removeRange(width, cells.length);
    } else {
      while (cells.length < width) {
        cells.add(Cell.blank);
      }
    }
  }

  /// The row's text: one cluster per cell, continuations skipped.
  String text() {
    final buf = StringBuffer();
    for (final cell in cells) {
      if (cell.isContinuation) continue;
      if (cell.text.isEmpty && cell.combining.isEmpty) {
        buf.write(' ');
      } else {
        buf.write(cell.cluster);
      }
    }
    return buf.toString();
  }

  /// True when every cell is the plain blank cell.
  bool get isBlank {
    for (final cell in cells) {
      if (!cell.isBlank) return false;
    }
    return true;
  }
}

/// Scrollback: archived rows with row-count AND cell-count caps; the oldest
/// rows are dropped until both hold. A wide glyph's continuation half counts
/// as a cell; combining marks do not.
class Scrollback {
  Scrollback({
    int maxRows = defaultMaxRows,
    int maxCells = defaultMaxCells,
  })  : maxRows = maxRows <= 0 ? defaultMaxRows : maxRows,
        maxCells = maxCells <= 0 ? defaultMaxCells : maxCells;

  /// Plan defaults: 10,000 rows and 1,000,000 stored cells.
  static const int defaultMaxRows = 10000;
  static const int defaultMaxCells = 1000000;

  final int maxRows;
  final int maxCells;

  final List<Row> _rows = <Row>[];
  int _cells = 0;

  int get length => _rows.length;

  int get storedCells => _cells;

  /// Appends [row] (adopting it; callers hand off ownership) and evicts.
  void push(Row row) {
    _rows.add(row);
    _cells += row.width;
    _trim();
  }

  void clear() {
    _rows.clear();
    _cells = 0;
  }

  void _trim() {
    var evict = 0;
    while (evict < _rows.length &&
        (_rows.length - evict > maxRows || _cells > maxCells)) {
      _cells -= _rows[evict].width;
      evict++;
    }
    if (evict > 0) {
      _rows.removeRange(0, evict);
    }
  }

  /// Unmodifiable view, oldest first.
  List<Row> get rows => List<Row>.unmodifiable(_rows);
}

/// One grid (primary or alternate) plus its cursor, margins, tabs, modes.
///
/// Both grids share geometry (the emulator resizes them together) but keep
/// independent cursor, saved-cursor, margin, tab, and mode state, so leaving
/// the alternate screen restores exactly what the primary had.
class TerminalGrid {
  TerminalGrid({
    required this.rows,
    required this.cols,
    Scrollback? scrollback,
  })  : scrollback = scrollback ?? Scrollback(),
        tabStops = _defaultTabStops(cols) {
    screen = List<Row>.generate(rows, (_) => Row.blank(cols));
  }

  static Set<int> _defaultTabStops(int cols) {
    final stops = <int>{};
    for (var c = 0; c < cols; c += 8) {
      stops.add(c);
    }
    return stops;
  }

  int rows;
  int cols;
  final Scrollback scrollback;
  final Set<int> tabStops;

  /// Cursor column (0-based) plus the DECAWM pending-wrap flag.
  int cursorRow = 0;
  int cursorCol = 0;
  bool pendingWrap = false;

  /// DECSC/DECRC slot.
  int savedCursorRow = 0;
  int savedCursorCol = 0;
  CellAttributes savedAttrs = CellAttributes.plain;
  bool savedOriginMode = false;
  bool savedPendingWrap = false;
  int savedG0 = 0;
  int savedG1 = 0;
  bool savedShift = false;

  /// Active SGR state applied to newly written cells.
  CellAttributes currentAttrs = CellAttributes.plain;

  /// Scroll margins (DECSTBM), inclusive screen indices; null = full screen.
  int? marginTop;
  int? marginBottom;

  /// DECOM.
  bool originMode = false;

  /// DECAWM.
  bool autowrap = true;

  /// IRM.
  bool insertMode = false;

  /// DECTCEM.
  bool cursorVisible = true;

  /// DECCKM.
  bool applicationCursorKeys = false;

  /// ESC = / ESC &gt;.
  bool applicationKeypad = false;

  /// DECSET 2004.
  bool bracketedPaste = false;

  /// DECSET 1004.
  bool focusReporting = false;

  /// DECSCNM.
  bool screenInverse = false;

  /// Character sets: 0 = ASCII, 1 = DEC Special Graphics (line drawing).
  int g0Charset = 0;
  int g1Charset = 0;

  /// SO (0x0e) selects G1 as the active set.
  bool shiftToG1 = false;

  /// Effective top margin.
  int get effectiveTop => marginTop ?? 0;

  /// Effective bottom margin (inclusive).
  int get effectiveBottom => marginBottom ?? rows - 1;

  /// Adds default tab stops (every 8 columns) below [cols]; idempotent and
  /// never removes stops, so shrinks keep existing stops as xterm does.
  void addDefaultTabStops(int cols) {
    for (var c = 0; c < cols; c += 8) {
      tabStops.add(c);
    }
  }

  /// Resets margins and origin mode and the pending-wrap flag (resize).
  void resetMargins() {
    marginTop = null;
    marginBottom = null;
    originMode = false;
    pendingWrap = false;
  }

  /// Writes [cell] at (row, col), healing wide-glyph pairs it splits.
  void putCell(int row, int col, Cell cell) {
    final cells = screen[row].cells;
    final old = cells[col];
    if (old.isContinuation && col > 0) {
      final lead = cells[col - 1];
      if (!lead.isContinuation && lead.text.isNotEmpty) {
        cells[col - 1] = Cell.blank;
      }
    }
    cells[col] = cell;
    if (!cell.isContinuation &&
        cell.text.isNotEmpty &&
        col + 1 < cols &&
        cells[col + 1].isContinuation) {
      // A narrow glyph overwrote a wide lead: drop the orphaned half.
      cells[col + 1] = Cell.blank;
    }
  }

  /// Writes the trailing half of a wide glyph.
  void putContinuation(int row, int col) {
    screen[row].cells[col] = const Cell(isContinuation: true);
  }

  /// The visible screen rows.
  late List<Row> screen;
}

/// Read-only view of one instant of the emulator, for renderers and tests.
class TerminalSnapshot {
  const TerminalSnapshot({
    required this.rows,
    required this.cols,
    required this.screen,
    required this.scrollback,
    required this.cursorRow,
    required this.cursorCol,
    required this.pendingWrap,
    required this.cursorVisible,
    required this.primaryActive,
    required this.screenInverse,
  });

  final int rows;
  final int cols;

  /// Deep-copied screen rows, top to bottom.
  final List<Row> screen;

  /// The live scrollback rows, oldest first (shared reference — treat as
  /// read-only; take a copy if the emulator keeps running).
  final List<Row> scrollback;

  final int cursorRow;
  final int cursorCol;
  final bool pendingWrap;
  final bool cursorVisible;
  final bool primaryActive;
  final bool screenInverse;
}
