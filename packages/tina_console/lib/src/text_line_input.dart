/// Immutable single-line text model with cursor tracking and history
/// navigation.
///
/// Pure data: every editing operation returns a **new** [TextLineInput]; this
/// object is never mutated in place. The host (a controller such as
/// [LineEditor]) holds the current value and reassigns it on each keystroke —
/// the same immutable-value pattern used by [LineLayout]/`computeLineLayout`.
/// No I/O lives here; the host decides when to redraw.
///
/// [buffer]/[cursor] always hold the *real* text (code-unit indices), so
/// submit, history, completion, and save/restore all keep working unchanged.
/// A bracketed paste is recorded as a [_PasteSpan] over a range of the real
/// buffer; [toDisplay]/[displayCursor] project that real text into a compact
/// `[Pasted text : N chars]` placeholder for rendering only.
///
/// The single-line sibling of [TextBuffer] (the multi-line model).
class TextLineInput {
  /// The real text under edit (code-unit indices).
  final String buffer;

  /// Cursor position within [buffer] (code-unit index).
  final int cursor;

  /// Submitted lines available for ↑/↓ recall. Immutable: [addHistory] returns
  /// a new [TextLineInput] with a new list rather than appending in place.
  final List<String> history;

  /// Current history-navigation index, or `-1` when not navigating.
  final int historyIndex;

  /// The in-progress draft saved when navigation begins, restored on
  /// navigating back past the newest entry.
  final String savedDraft;

  /// Ranges of [buffer] that are pasted text, shown as placeholders when
  /// rendering. Sorted by [start] and non-overlapping. Immutable.
  final List<_PasteSpan> pasteSpans;

  const TextLineInput({
    this.buffer = '',
    this.cursor = 0,
    List<String>? history,
    this.historyIndex = -1,
    this.savedDraft = '',
    List<_PasteSpan>? pasteSpans,
  })  : history = history ?? const [],
        pasteSpans = pasteSpans ?? const [];

  /// Derive a copy with selected fields replaced. The standard companion to
  /// immutability; the editing methods below are the preferred, named ways to
  /// transform a value, but this is the escape hatch for setup and tests.
  TextLineInput copyWith({
    String? buffer,
    int? cursor,
    List<String>? history,
    int? historyIndex,
    String? savedDraft,
    List<_PasteSpan>? pasteSpans,
  }) =>
      TextLineInput(
        buffer: buffer ?? this.buffer,
        cursor: cursor ?? this.cursor,
        history: history ?? this.history,
        historyIndex: historyIndex ?? this.historyIndex,
        savedDraft: savedDraft ?? this.savedDraft,
        pasteSpans: pasteSpans ?? this.pasteSpans,
      );

  /// Insert [text] at the cursor position and advance the cursor.
  TextLineInput insert(String text) => copyWith(
        buffer: buffer.substring(0, cursor) + text + buffer.substring(cursor),
        cursor: cursor + text.length,
        pasteSpans: _shift(pasteSpans, cursor, text.length),
      );

  /// Insert a pasted block as an atomic token: the real text goes into
  /// [buffer] at the cursor, a span is recorded over it, and the cursor lands
  /// at the span's right edge. The placeholder is display-only.
  TextLineInput addPaste(String text) {
    final start = cursor;
    // Mirrors insert(): shift any spans at/after the cursor, rebuild the
    // buffer, land the cursor at the end.
    final shifted = _shift(pasteSpans, start, text.length);
    final newBuffer =
        buffer.substring(0, start) + text + buffer.substring(start);
    final end = start + text.length;
    final spans =
        _insertSpanInto(shifted, _PasteSpan(start, end, _makePlaceholder(text)));
    return copyWith(buffer: newBuffer, cursor: end, pasteSpans: spans);
  }

  /// Delete the code point before the cursor (surrogate-aware). If the cursor
  /// sits at a paste span's right edge, the whole span is removed instead.
  TextLineInput backspace() {
    if (cursor == 0) return this;
    final span = _spanAtRightEdge(cursor);
    if (span != null) return _deleteSpan(span);
    var start = cursor - 1;
    if (start > 0) {
      final unit = buffer.codeUnitAt(start);
      if (unit >= 0xDC00 && unit <= 0xDFFF) start--;
    }
    return _removeRange(start, cursor, start);
  }

  /// Delete the code point after the cursor (surrogate-aware). If the cursor
  /// sits at a paste span's left edge, the whole span is removed instead.
  TextLineInput deleteForward() {
    if (cursor >= buffer.length) return this;
    final span = _spanAtLeftEdge(cursor);
    if (span != null) return _deleteSpan(span);
    var end = cursor + 1;
    if (end < buffer.length) {
      final unit = buffer.codeUnitAt(end - 1);
      if (unit >= 0xD800 && unit <= 0xDBFF) end++;
    }
    return _removeRange(cursor, end, cursor);
  }

  /// Move cursor left by one code point (surrogate-aware). If the move would
  /// land strictly inside a paste span, snap to the span's left edge so the
  /// paste is skipped over as one unit.
  TextLineInput moveLeft() {
    if (cursor == 0) return this;
    var n = 1;
    if (cursor >= 2) {
      final unit = buffer.codeUnitAt(cursor - 1);
      if (unit >= 0xDC00 && unit <= 0xDFFF) n = 2;
    }
    return copyWith(cursor: _snapLeft(cursor - n));
  }

  /// Move cursor right by one code point (surrogate-aware). Snaps to a span's
  /// right edge when the move would land inside a paste.
  TextLineInput moveRight() {
    if (cursor >= buffer.length) return this;
    var n = 1;
    if (cursor + 1 < buffer.length) {
      final unit = buffer.codeUnitAt(cursor);
      if (unit >= 0xD800 && unit <= 0xDBFF) n = 2;
    }
    return copyWith(cursor: _snapRight(cursor + n));
  }

  /// Move cursor to the start of the buffer.
  TextLineInput moveHome() => copyWith(cursor: 0);

  /// Move cursor to the end of the buffer.
  TextLineInput moveEnd() => copyWith(cursor: buffer.length);

  /// Delete from cursor to end of buffer. Any paste span at or after the
  /// cursor (or overlapping it) is removed.
  TextLineInput killToEnd() {
    final kept = pasteSpans.where((s) => s.end <= cursor).toList();
    return copyWith(buffer: buffer.substring(0, cursor), pasteSpans: kept);
  }

  /// Delete from start of buffer to cursor. Any paste span at or before the
  /// cursor (or overlapping it) is removed; remaining spans shift left.
  TextLineInput killToStart() {
    final deleted = cursor;
    final kept = pasteSpans
        .where((s) => s.start >= cursor)
        .map((s) => _PasteSpan(s.start - deleted, s.end - deleted, s.placeholder))
        .toList();
    return copyWith(buffer: buffer.substring(cursor), cursor: 0, pasteSpans: kept);
  }

  /// Clear the entire buffer, cursor, and paste spans. History is preserved.
  TextLineInput clear() => copyWith(buffer: '', cursor: 0, pasteSpans: const []);

  /// Drop all paste spans without touching the real buffer. Used when the
  /// host restores a panel's edit state (which carries only real text).
  TextLineInput clearSpans() => copyWith(pasteSpans: const []);

  /// Load real [buffer]/[cursor] (e.g. when restoring a panel's input),
  /// clearing any live paste spans. History and navigation state are
  /// preserved.
  TextLineInput loadState(String buffer, int cursor) =>
      copyWith(buffer: buffer, cursor: cursor, pasteSpans: const []);

  /// Replace a range of the buffer. Used by the completion picker to
  /// substitute the trigger+query with the selected result. Any paste span
  /// overlapping the replaced range is removed; later spans shift.
  TextLineInput replaceRange(int start, int end, String replacement) {
    final kept = _removeOverlapping(pasteSpans, start, end);
    final newBuffer =
        buffer.substring(0, start) + replacement + buffer.substring(end);
    final delta = replacement.length - (end - start);
    return copyWith(
      buffer: newBuffer,
      cursor: start + replacement.length,
      pasteSpans: _shift(kept, end, delta),
    );
  }

  /// Navigate to the previous history entry. History holds real text only;
  /// navigating clears any live paste spans.
  TextLineInput historyUp() {
    if (history.isEmpty) return this;
    final int newIndex;
    final String draft;
    if (historyIndex == -1) {
      draft = buffer;
      newIndex = history.length - 1;
    } else if (historyIndex > 0) {
      draft = savedDraft;
      newIndex = historyIndex - 1;
    } else {
      return this;
    }
    final newBuffer = history[newIndex];
    return copyWith(
      buffer: newBuffer,
      cursor: newBuffer.length,
      pasteSpans: const [],
      historyIndex: newIndex,
      savedDraft: draft,
    );
  }

  /// Navigate to the next history entry (or restore the draft).
  TextLineInput historyDown() {
    if (historyIndex == -1) return this;
    final next = historyIndex + 1;
    final String newBuffer;
    final int finalIndex;
    if (next >= history.length) {
      finalIndex = -1;
      newBuffer = savedDraft;
    } else {
      finalIndex = next;
      newBuffer = history[next];
    }
    return copyWith(
      buffer: newBuffer,
      cursor: newBuffer.length,
      pasteSpans: const [],
      historyIndex: finalIndex,
    );
  }

  /// Move cursor to the start of the previous word (whitespace-delimited).
  TextLineInput moveWordLeft() {
    if (cursor == 0) return this;
    var pos = cursor - 1;
    while (pos >= 0 &&
        (buffer.codeUnitAt(pos) == 0x20 || buffer.codeUnitAt(pos) == 0x09)) {
      pos--;
    }
    while (pos >= 0) {
      final c = buffer.codeUnitAt(pos);
      if (c == 0x20 || c == 0x09) break;
      pos--;
    }
    return copyWith(cursor: _snapLeft(pos + 1));
  }

  /// Move cursor to the start of the next word (whitespace-delimited).
  TextLineInput moveWordRight() {
    if (cursor >= buffer.length) return this;
    var pos = cursor;
    while (pos < buffer.length) {
      final c = buffer.codeUnitAt(pos);
      if (c == 0x20 || c == 0x09) break;
      pos++;
    }
    while (pos < buffer.length) {
      final c = buffer.codeUnitAt(pos);
      if (c != 0x20 && c != 0x09) break;
      pos++;
    }
    return copyWith(cursor: _snapRight(pos));
  }

  /// Delete from cursor backward to the previous word boundary.
  TextLineInput killWordBackward() {
    final saved = cursor;
    final moved = moveWordLeft();
    if (moved.cursor < saved) {
      return moved._removeRange(moved.cursor, saved, moved.cursor);
    }
    return moved;
  }

  /// Delete from cursor forward to the next word boundary.
  TextLineInput killWordForward() {
    if (cursor >= buffer.length) return this;
    final saved = cursor;
    final moved = moveWordRight();
    if (moved.cursor > saved) {
      return moved._removeRange(saved, moved.cursor, saved);
    }
    return moved;
  }

  /// Whether cursor is at start of buffer or preceded by whitespace/tab.
  bool atWordBoundary() {
    if (cursor == 0) return true;
    final prev = buffer.codeUnitAt(cursor - 1);
    return prev == 0x20 || prev == 0x09;
  }

  /// Add a line to history (deduped against the last entry). Returns `this`
  /// unchanged when the line is blank/whitespace or a repeat of the last.
  TextLineInput addHistory(String line) {
    if (line.trim().isNotEmpty &&
        (history.isEmpty || history.last != line)) {
      return copyWith(history: [...history, line]);
    }
    return this;
  }

  /// Reset history navigation state (for a new readLine session).
  TextLineInput resetNavigation() =>
      copyWith(historyIndex: -1, savedDraft: '');

  // -- Pure reads (no copyWith) -----------------------------------------

  /// Rebuild [buffer] with each paste span's real text replaced by its
  /// placeholder, for display only. The result is a code-unit string whose
  /// placeholder segments are ASCII (code-unit length == column width).
  String toDisplay() {
    if (pasteSpans.isEmpty) return buffer;
    final sb = StringBuffer();
    var offset = 0;
    for (final span in pasteSpans) {
      sb.write(buffer.substring(offset, span.start));
      sb.write(span.placeholder);
      offset = span.end;
    }
    sb.write(buffer.substring(offset));
    return sb.toString();
  }

  /// Map a real-text [cursor] index into display space by subtracting the
  /// difference between each preceding span's real length and its placeholder
  /// length.
  int displayCursor(int cursor) {
    var display = cursor;
    for (final span in pasteSpans) {
      if (span.end <= cursor) {
        display -= (span.end - span.start) - span.placeholder.length;
      }
    }
    return display;
  }

  // -- Paste span plumbing (all pure: return new lists) ----------------

  /// Add [delta] to the bounds of every span at or after [from].
  static List<_PasteSpan> _shift(List<_PasteSpan> spans, int from, int delta) {
    if (delta == 0) return spans;
    return [
      for (final s in spans)
        s.start >= from
            ? _PasteSpan(s.start + delta, s.end + delta, s.placeholder)
            : s,
    ];
  }

  /// Drop every span overlapping `[start, end)`.
  static List<_PasteSpan> _removeOverlapping(
          List<_PasteSpan> spans, int start, int end) =>
      spans.where((s) => !(s.start < end && s.end > start)).toList();

  /// Insert [span] into [spans], keeping the list sorted by [start].
  static List<_PasteSpan> _insertSpanInto(
      List<_PasteSpan> spans, _PasteSpan span) {
    var i = spans.length;
    while (i > 0 && spans[i - 1].start > span.start) {
      i--;
    }
    return [...spans.sublist(0, i), span, ...spans.sublist(i)];
  }

  /// The span whose right edge is exactly [cursor], or null.
  _PasteSpan? _spanAtRightEdge(int cursor) {
    for (final s in pasteSpans) {
      if (s.end == cursor) return s;
    }
    return null;
  }

  /// The span whose left edge is exactly [cursor], or null.
  _PasteSpan? _spanAtLeftEdge(int cursor) {
    for (final s in pasteSpans) {
      if (s.start == cursor) return s;
    }
    return null;
  }

  /// If [cursor] landed strictly inside a span (a left move crossed into one),
  /// snap it to that span's left edge.
  int _snapLeft(int cursor) {
    for (final s in pasteSpans) {
      if (s.start < cursor && cursor <= s.end) return s.start;
    }
    return cursor;
  }

  /// If [cursor] landed strictly inside a span (a right move crossed into one),
  /// snap it to that span's right edge.
  int _snapRight(int cursor) {
    for (final s in pasteSpans) {
      if (s.start <= cursor && cursor < s.end) return s.end;
    }
    return cursor;
  }

  /// Remove a span's real text from [buffer], shift later spans, and place the
  /// cursor at the span's former left edge.
  TextLineInput _deleteSpan(_PasteSpan span) {
    final len = span.end - span.start;
    final newBuffer =
        buffer.substring(0, span.start) + buffer.substring(span.end);
    final kept = [...pasteSpans]..remove(span);
    return copyWith(
      buffer: newBuffer,
      cursor: span.start,
      pasteSpans: _shift(kept, span.end, -len),
    );
  }

  /// Delete a real-text range `[start, end)`: remove the substring, drop any
  /// span overlapping the range, shift later spans, and set the cursor to
  /// [newCursor].
  TextLineInput _removeRange(int start, int end, int newCursor) {
    final kept = _removeOverlapping(pasteSpans, start, end);
    final newBuffer = buffer.substring(0, start) + buffer.substring(end);
    return copyWith(
      buffer: newBuffer,
      cursor: newCursor,
      pasteSpans: _shift(kept, end, -(end - start)),
    );
  }

  String _makePlaceholder(String text) =>
      '[Pasted text : ${text.runes.length} chars]';
}

/// A range of [TextLineInput.buffer] that was pasted and is shown as a
/// placeholder. Immutable.
class _PasteSpan {
  final int start;
  final int end;
  final String placeholder;
  const _PasteSpan(this.start, this.end, this.placeholder);
}
