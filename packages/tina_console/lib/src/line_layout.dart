/// Where the cursor and the buffer's last cell land when a prompt+buffer is
/// wrapped at a terminal width. Pure math — no I/O — so it's directly
/// testable. Rows are 0-indexed from the prompt's first row.
class LineLayout {
  final int cursorRow;
  final int cursorCol;

  /// Row of the buffer's last character. Equals 0 when the buffer is empty.
  final int endRow;

  const LineLayout({
    required this.cursorRow,
    required this.cursorCol,
    required this.endRow,
  });
}

/// Compute the on-screen layout of a prompt+buffer at terminal width [cols].
/// Assumes each buffer character occupies exactly one terminal column —
/// good enough for ASCII; emoji / CJK / combining marks degrade gracefully
/// (cursor drift, never a crash). A proper grapheme-width pass is out of
/// scope here.
///
/// [promptCols] is the display width of the prompt with ANSI escapes
/// already stripped. [bufferLen] and [cursor] are character counts in the
/// buffer (with [cursor] in `[0, bufferLen]`).
LineLayout computeLineLayout({
  required int promptCols,
  required int bufferLen,
  required int cursor,
  required int cols,
}) {
  final width = cols <= 0 ? 80 : cols;
  final cursorTotal = promptCols + cursor;
  final endTotal = promptCols + bufferLen;
  return LineLayout(
    cursorRow: cursorTotal ~/ width,
    cursorCol: cursorTotal % width,
    endRow: endTotal == 0 ? 0 : (endTotal - 1) ~/ width,
  );
}

/// Strip ANSI CSI sequences from [s] for column-counting purposes. Doesn't
/// try to be comprehensive — only the SGR-family escapes that show up in
/// our own colored prompts.
String stripAnsi(String s) =>
    s.replaceAll(RegExp(r'\x1B\[[0-9;?]*[a-zA-Z]'), '');
