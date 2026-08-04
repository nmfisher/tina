/// Lightweight ANSI terminal emulator for integration tests.
///
/// Parses the escape sequences emitted by SplitFrame, PanelRenderer,
/// Spinner, and ProgressCounter, tracking cell state in a 2D grid.
/// Does NOT handle: scrolling, tab stops, insert/delete lines, alternate
/// screen buffer modes — none of those are needed for the rendering
/// pipeline tests.
library;

/// A single cell in the virtual terminal.
class _Cell {
  String char;
  _Cell({this.char = ' '});
}

/// Minimal ANSI virtual terminal.
///
/// Usage:
/// ```dart
///   final vt = VirtualTerminal(width: 100, height: 24);
///   vt.feed('\x1b[2;3Hhello');
///   expect(vt.charAt(1, 2), 'h'); // row 1, col 2 (0-indexed)
/// ```
class VirtualTerminal {
  final int width;
  final int height;
  late final List<List<_Cell>> grid;

  int _cursorRow = 0;
  int _cursorCol = 0;
  bool _pendingWrap = false;

  int get cursorRow => _cursorRow;
  int get cursorCol => _cursorCol;

  int _savedRow = 0;
  int _savedCol = 0;

  VirtualTerminal({required this.width, required this.height}) {
    grid = List.generate(height, (_) => List.generate(width, (_) => _Cell()));
  }

  /// Parse ANSI escape sequences and printable characters from [s].
  void feed(String s) {
    var i = 0;
    final runes = s.runes.toList();
    while (i < runes.length) {
      final ch = runes[i];
      if (ch == 0x1b) {
        i = _handleEscape(s, runes, i);
      } else if (ch == 0x0d) {
        _cursorCol = 0;
        _pendingWrap = false;
        i++;
      } else if (ch == 0x0a) {
        _cursorRow++;
        _pendingWrap = false;
        if (_cursorRow >= height) _cursorRow = height - 1;
        i++;
      } else if (ch >= 0x20) {
        _putChar(String.fromCharCode(ch));
        i++;
      } else {
        i++; // skip other control chars
      }
    }
  }

  /// Return all characters in row [r] (0-indexed) as a string.
  String rowText(int r) {
    final buf = StringBuffer();
    for (final c in grid[r]) {
      buf.write(c.char);
    }
    return buf.toString();
  }

  /// Return the character at row [r], column [c] (0-indexed).
  /// Returns ' ' if out of bounds.
  String charAt(int r, int c) {
    if (r < 0 || r >= height || c < 0 || c >= width) return ' ';
    return grid[r][c].char;
  }

  /// Assert that row [row] (0-indexed) has `│` at [leftCol], [divCol],
  /// and [rightCol] (0-indexed columns).
  void assertBorders(int row, int leftCol, int divCol, int rightCol) {
    final r = rowText(row);
    assert(
      r[leftCol] == '│',
      'Row $row col $leftCol: expected │, got ${r[leftCol]}',
    );
    assert(
      r[divCol] == '│',
      'Row $row col $divCol: expected │, got ${r[divCol]}',
    );
    assert(
      r[rightCol] == '│',
      'Row $row col $rightCol: expected │, got ${r[rightCol]}',
    );
  }

  /// Assert that row [row] (0-indexed) matches [expected] exactly.
  void assertRow(int row, String expected) {
    final actual = rowText(row);
    assert(
      actual == expected,
      'Row $row mismatch:\n  expected: $expected\n  actual:   $actual',
    );
  }

  /// Assert that no cell in the interior of the left panel (cols 1..divCol-1,
  /// 0-indexed) on any content row (rows 1..height-2) contains a border
  /// character (`│` or `─` or any box-drawing char).
  /// [skipRows] are excluded from the check (e.g. separator rows with `├─┼─┤`).
  void assertNoBorderCharsInLeftInterior(int divCol, {Set<int>? skipRows}) {
    for (var r = 1; r < height - 1; r++) {
      if (skipRows != null && skipRows.contains(r)) continue;
      for (var c = 1; c < divCol; c++) {
        final ch = charAt(r, c);
        assert(
          !isBoxDrawingChar(ch),
          'Unexpected border char "$ch" at row $r col $c (left interior)',
        );
      }
    }
  }

  /// Assert that no cell in the interior of the right panel
  /// (cols divCol+1..width-2) on any content row contains a border character.
  /// [skipRows] are excluded from the check.
  void assertNoBorderCharsInRightInterior(int divCol, {Set<int>? skipRows}) {
    for (var r = 1; r < height - 1; r++) {
      if (skipRows != null && skipRows.contains(r)) continue;
      for (var c = divCol + 1; c < width - 1; c++) {
        final ch = charAt(r, c);
        assert(
          !isBoxDrawingChar(ch),
          'Unexpected border char "$ch" at row $r col $c (right interior)',
        );
      }
    }
  }

  // -- internals -----------------------------------------------------------

  void _putChar(String ch) {
    if (_pendingWrap) {
      _cursorCol = 0;
      _cursorRow++;
      _pendingWrap = false;
      if (_cursorRow >= height) _cursorRow = height - 1;
    }
    if (_cursorRow >= 0 &&
        _cursorRow < height &&
        _cursorCol >= 0 &&
        _cursorCol < width) {
      grid[_cursorRow][_cursorCol] = _Cell(char: ch);
      _cursorCol++;
      if (_cursorCol >= width) {
        _pendingWrap = true;
        _cursorCol = width - 1;
      }
    }
  }

  int _handleEscape(String s, List<int> runes, int start) {
    if (start + 1 >= runes.length) return start + 1;
    final next = runes[start + 1];
    if (next == 0x37) {
      // ESC 7 — save cursor
      _savedRow = _cursorRow;
      _savedCol = _cursorCol;
      return start + 2;
    }
    if (next == 0x38) {
      // ESC 8 — restore cursor
      _cursorRow = _savedRow;
      _cursorCol = _savedCol;
      _pendingWrap = false;
      return start + 2;
    }
    if (next == 0x5b) return _handleCsi(s, runes, start);
    if (next == 0x4f) return start + 3; // SS3
    return start + 2;
  }

  int _handleCsi(String s, List<int> runes, int start) {
    var j = start + 2;
    if (j < runes.length && runes[j] == 0x3f) j++; // ? prefix
    final buf = StringBuffer();
    while (j < runes.length) {
      final ch = runes[j];
      if ((ch >= 0x30 && ch <= 0x3f) || ch == 0x3b) {
        buf.write(String.fromCharCode(ch));
        j++;
      } else {
        break;
      }
    }
    if (j >= runes.length) return j;
    final params = buf.toString();
    final cmd = runes[j];
    j++;

    // Split params on ';' for multi-param commands.
    final paramList = params.isEmpty ? <String>[] : params.split(';');

    switch (cmd) {
      case 0x47: // G — cursor horizontal absolute
        _cursorCol = (paramList.isEmpty ? 1 : int.parse(paramList.last)) - 1;
        _pendingWrap = false;
      case 0x48: // H — cursor position
        _pendingWrap = false;
        _cursorRow = (paramList.isEmpty ? 1 : int.parse(paramList[0])) - 1;
        _cursorCol = paramList.length > 1
            ? int.parse(paramList[1]) - 1
            : 0;
      case 0x4a: // J — erase in display
        final n = paramList.isEmpty ? '0' : paramList[0];
        if (n == '0') {
          // Erase from cursor to end of screen.
          for (var c = _cursorCol; c < width; c++) {
            grid[_cursorRow][c] = _Cell();
          }
          for (var r = _cursorRow + 1; r < height; r++) {
            for (var c = 0; c < width; c++) {
              grid[r][c] = _Cell();
            }
          }
        } else if (n == '2') {
          _clearScreen();
        }
      case 0x4b: // K — erase in line
        final n = paramList.isEmpty ? '0' : paramList[0];
        if (n == '0') {
          for (var c = _cursorCol; c < width; c++) {
            grid[_cursorRow][c] = _Cell();
          }
        } else if (n == '1') {
          for (var c = 0; c <= _cursorCol && c < width; c++) {
            grid[_cursorRow][c] = _Cell();
          }
        }
      case 0x58: // X — erase characters
        final n = paramList.isEmpty ? 1 : int.parse(paramList.last);
        for (var k = 0; k < n && _cursorCol + k < width; k++) {
          grid[_cursorRow][_cursorCol + k] = _Cell();
        }
      case 0x41: // A — cursor up
        _cursorRow -= paramList.isEmpty ? 1 : int.parse(paramList.last);
        if (_cursorRow < 0) _cursorRow = 0;
      case 0x42: // B — cursor down
        _cursorRow += paramList.isEmpty ? 1 : int.parse(paramList.last);
        if (_cursorRow >= height) _cursorRow = height - 1;
      case 0x43: // C — cursor forward
        _cursorCol += paramList.isEmpty ? 1 : int.parse(paramList.last);
        if (_cursorCol >= width) _cursorCol = width - 1;
      case 0x44: // D — cursor back
        _cursorCol -= paramList.isEmpty ? 1 : int.parse(paramList.last);
        if (_cursorCol < 0) _cursorCol = 0;
      case 0x6d: // m — SGR (consumed, ignored)
        break;
      case 0x68: // h — set mode (consumed)
      case 0x6c: // l — reset mode (consumed)
        break;
    }
    return j;
  }

  void _clearScreen() {
    for (var r = 0; r < height; r++) {
      for (var c = 0; c < width; c++) {
        grid[r][c] = _Cell();
      }
    }
    _cursorRow = 0;
    _cursorCol = 0;
  }

  static bool isBoxDrawingChar(String ch) {
    if (ch.length != 1) return false;
    final cp = ch.runes.first;
    return cp >= 0x2500 && cp <= 0x257F;
  }
}
