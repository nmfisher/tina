/// Multi-line text buffer with a (line, col) cursor.
///
/// Pure data — no I/O; the host decides when to redraw. Mirrors [TextLineInput]'s
/// style for the single-line primitives, extended across `\n` line breaks: the
/// cursor is a `(line, col)` pair, and edits that cross a break split or join
/// lines. All code-point movement is surrogate-aware, like [TextLineInput].
///
/// As with [TextLineInput.buffer] / [TextLineInput.cursor], [line] and [col] are public
/// mutable fields — a setup/test escape hatch. The editing methods below keep
/// them consistent; assigning directly is the caller's responsibility.
class TextBuffer {
  List<String> _lines;

  /// Current cursor line (0-based).
  int line;

  /// Current cursor column within [line] (0-based).
  int col;

  /// Seed from [initial] (split on `\n`). The cursor starts at the end of the
  /// text — the natural "open for editing" position.
  TextBuffer({String initial = ''})
      : _lines = initial.split('\n'),
        line = 0,
        col = 0 {
    if (_lines.isEmpty) _lines = [''];
    line = _lines.length - 1;
    col = _lines.last.length;
  }

  /// The full text, lines joined by `\n`.
  String get text => _lines.join('\n');

  /// An unmodifiable view of the lines.
  List<String> get lines => List.unmodifiable(_lines);

  /// Number of lines (always >= 1).
  int get lineCount => _lines.length;

  /// The text of the current line.
  String get currentLine => _lines[line];

  /// Insert [text] at the cursor. A [text] containing `\n` splits the current
  /// line into several; the cursor lands after the inserted text.
  void insert(String text) {
    if (text.isEmpty) return;
    final l = _lines[line];
    final prefix = l.substring(0, col);
    final suffix = l.substring(col);
    final parts = text.split('\n');
    if (parts.length == 1) {
      _lines[line] = prefix + text + suffix;
      col += text.length;
      return;
    }
    _lines[line] = prefix + parts.first;
    for (var i = 1; i < parts.length; i++) {
      _lines.insert(line + i, i == parts.length - 1 ? parts[i] + suffix : parts[i]);
    }
    line += parts.length - 1;
    col = parts.last.length;
  }

  /// Break the current line at the cursor (Enter). Equivalent to `insert('\n')`.
  void splitLine() {
    final l = _lines[line];
    final prefix = l.substring(0, col);
    final suffix = l.substring(col);
    _lines[line] = prefix;
    _lines.insert(line + 1, suffix);
    line++;
    col = 0;
  }

  /// Delete the code point before the cursor. At column 0, joins the current
  /// line onto the end of the previous one (no-op on the first line).
  void backspace() {
    if (col == 0) {
      if (line == 0) return;
      final cur = _lines.removeAt(line);
      line--;
      final prev = _lines[line];
      col = prev.length;
      _lines[line] = prev + cur;
      return;
    }
    final l = _lines[line];
    var start = col - 1;
    if (start > 0) {
      final unit = l.codeUnitAt(start);
      if (unit >= 0xDC00 && unit <= 0xDFFF) start--;
    }
    _lines[line] = l.substring(0, start) + l.substring(col);
    col = start;
  }

  /// Delete the code point after the cursor. At end of line, joins the next
  /// line onto the current one (no-op on the last line).
  void deleteForward() {
    final l = _lines[line];
    if (col == l.length) {
      if (line == _lines.length - 1) return;
      final next = _lines.removeAt(line + 1);
      _lines[line] = l + next;
      return;
    }
    var end = col + 1;
    if (end < l.length) {
      final unit = l.codeUnitAt(end - 1);
      if (unit >= 0xD800 && unit <= 0xDBFF) end++;
    }
    _lines[line] = l.substring(0, col) + l.substring(end);
  }

  /// Move cursor left by one code point. At column 0, jumps to the end of the
  /// previous line (no-op on the first line).
  void moveLeft() {
    if (col > 0) {
      var n = 1;
      if (col >= 2) {
        final unit = _lines[line].codeUnitAt(col - 1);
        if (unit >= 0xDC00 && unit <= 0xDFFF) n = 2;
      }
      col -= n;
      return;
    }
    if (line > 0) {
      line--;
      col = _lines[line].length;
    }
  }

  /// Move cursor right by one code point. At end of line, jumps to the start of
  /// the next line (no-op on the last line).
  void moveRight() {
    final l = _lines[line];
    if (col < l.length) {
      var n = 1;
      if (col + 1 < l.length) {
        final unit = l.codeUnitAt(col);
        if (unit >= 0xD800 && unit <= 0xDBFF) n = 2;
      }
      col += n;
      return;
    }
    if (line < _lines.length - 1) {
      line++;
      col = 0;
    }
  }

  /// Move cursor up one line, clamping the column to the target line's length.
  void moveUp() {
    if (line == 0) return;
    line--;
    final len = _lines[line].length;
    if (col > len) col = len;
  }

  /// Move cursor down one line, clamping the column to the target line's length.
  void moveDown() {
    if (line == _lines.length - 1) return;
    line++;
    final len = _lines[line].length;
    if (col > len) col = len;
  }

  /// Move cursor to the start of the current line.
  void moveLineHome() => col = 0;

  /// Move cursor to the end of the current line.
  void moveLineEnd() => col = _lines[line].length;

  /// Clear all text and reset the cursor.
  void clear() {
    _lines = [''];
    line = 0;
    col = 0;
  }
}
