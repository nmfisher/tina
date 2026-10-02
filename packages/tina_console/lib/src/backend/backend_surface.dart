import '../rect.dart';
import '../term_width.dart';

/// A bounded, positioned write surface owned by a [TerminalBackend].
///
/// This is the backend-side counterpart to [Region]'s app-side "rectangle of
/// the screen" abstraction. A [BackendSurface] is an opaque handle to whatever
/// the rendering backend uses for an independent drawable area:
///
/// - On the **notcurses** backend it is a real child `ncplane`, giving genuine
///   z-ordering ([raiseToTop]/[lowerToBottom]) and cheap move/resize.
/// - On the **ANSI** backend it is emulated as a rect offset over the single
///   terminal surface: writes are translated to absolute coordinates and
///   routed through the same batched buffer as everything else ([Screen]
///   already clips, so emulation is bookkeeping + translation).
///
/// Coordinates passed to [putAt] / [eraseAt] are **relative** to the surface's
/// own origin (0,0 = its top-left). Each backend translates them as needed.
///
/// Visibility (show/hide) is deliberately **not** part of this interface.
/// notcurses has no native hide/show, so panel show/hide is handled one layer
/// up, at the [Panel]/[Screen] level: a panel retains its row buffer (the way
/// [ChatRegion] does), so hiding = stop emitting + erase the area, and showing
/// = re-emit from the buffer. That works identically on both backends.
abstract class BackendSurface {
  /// Current absolute bounds (origin + size) of this surface.
  Rect get bounds;

  /// Write a single line of [text] starting at the relative ([relRow],
  /// [relCol]). Writes are clipped to the surface's right edge. An origin
  /// outside the surface or a nonpositive budget is a no-op.
  /// ANSI escapes in [text] are preserved but don't consume columns.
  ///
  /// [moveCursor] = false wraps the write in save/restore so the terminal's
  /// visible cursor (parked by the input region) doesn't jump — use this for
  /// panel content that isn't the editing row.
  ///
  /// [clearCells] is the number of cells the destination span is known to
  /// have painted previously (the caller's snapshot of the row's old
  /// extent). The surface erases only that span before writing — bounded by
  /// the previous content instead of the full [maxCols] budget. Null means
  /// the previous extent is unknown (first paint, geometry change): erase
  /// the full budget, the pre-tin-p8k2 behaviour.
  void putAt({
    required int relRow,
    required int relCol,
    required String text,
    required int maxCols,
    required bool moveCursor,
    int? clearCells,
  });

  /// Erase [n] cells starting at the relative ([relRow], [relCol]).
  /// Uses the same bounds and no-op rules as [putAt].
  void eraseAt({
    required int relRow,
    required int relCol,
    required int n,
    required bool moveCursor,
  });

  /// Move the surface origin to absolute ([row], [col]).
  void moveTo(int row, int col);

  /// Resize the surface to [width] x [height] cells. Existing content is not
  /// preserved by the backend; the owner is expected to re-render.
  void resize(int width, int height);

  /// Bring this surface above its siblings in the z-order.
  void raiseToTop();

  /// Push this surface below its siblings in the z-order.
  void lowerToBottom();

  /// Scroll the surface's contents up by [count] rows, exposing [count] blank
  /// rows at the bottom. Returns `true` if the backend performed a native
  /// scroll (notcurses: `ncplane_scrollup`); `false` if the surface has no
  /// native scroll (ANSI/passthrough) so the caller falls back to a full
  /// redraw.
  ///
  /// On notcurses the plane must be a "scrolling plane" for [scrollUp] to
  /// succeed (otherwise it returns an error); the implementation enables
  /// scrolling lazily on the first call.
  bool scrollRows(int count);

  /// Release backend resources for this surface. Safe to call once.
  void destroy();
}

/// A real layer whose pixels survive drawing to other surfaces. Unlike a
/// shared-grid offset, it can retain unchanged overlay rows without damage
/// notifications from the rest of the screen.
abstract interface class LayeredBackendSurface {}

/// Limit a surface operation to its row, without allowing invalid origins.
int clippedSurfaceColumns(Rect bounds, int relRow, int relCol, int columns) {
  if (columns <= 0 ||
      relRow < 0 ||
      relRow >= bounds.height ||
      relCol < 0 ||
      relCol >= bounds.width) {
    return 0;
  }
  final remaining = bounds.width - relCol;
  return columns < remaining ? columns : remaining;
}

/// Clip one painted row to [maxCols] cells. Preserve SGR styling only: text
/// cannot move the terminal cursor, erase another row or change terminal modes.
/// Source line breaks and tabs degrade to spaces; layout belongs to the caller.
///
/// The budget is terminal cells (wide runes 2, combining 0 — see
/// term_width.dart), so a clipped string can never lay out wider than
/// [maxCols] on the real terminal and autowrap onto the next screen row
/// (tin-q4vz). A rune that would cross the budget is dropped whole — a
/// surrogate pair is never split.
///
/// Mirrors the clipping [Screen] applies to its own region writes; factored
/// out so backend surfaces clip identically.
String clipToVisibleColumns(String s, int maxCols) {
  if (maxCols <= 0) return '';
  var visible = 0;
  final sb = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final unit = s.codeUnitAt(i);
    if (unit == 0x1b || (unit >= 0x80 && unit <= 0x9f)) {
      final sgr = _rowSgr.matchAsPrefix(s, i);
      if (sgr != null) {
        sb.write(sgr.group(0));
        i = sgr.end;
      } else {
        i = _skipControlSequence(s, i);
      }
      continue;
    }
    if (unit < 0x20 || unit == 0x7f) {
      if (unit == 0x09 || unit == 0x0a || unit == 0x0d) {
        if (visible == maxCols) break;
        sb.write(' ');
        visible++;
        // A CRLF is one source break.
        if (unit == 0x0d && i + 1 < s.length && s.codeUnitAt(i + 1) == 0x0a) {
          i++;
        }
      }
      i++;
      continue;
    }
    final size = runeSizeAt(s, i);
    final width = runeWidth(codePointAt(s, i));
    // Zero-width runes (combining marks) attach to the previous glyph even at
    // a full budget; anything wider stops the clip here.
    if (visible + width > maxCols) break;
    sb.write(s.substring(i, i + size));
    visible += width;
    i += size;
  }
  return sb.toString();
}

final _rowSgr = RegExp(r'\x1b\[[0-9;:]*m');

/// Consume the whole sequence, including OSC/DCS payloads and charset escapes
/// such as ESC ) B. Dropping only ESC would paint their trailing letters.
int _skipControlSequence(String text, int start) {
  var i = start;
  var kind = text.codeUnitAt(i++);
  if (kind == 0x1b) {
    if (i == text.length) return i;
    kind = text.codeUnitAt(i++);
  }
  if (kind == 0x5b || kind == 0x9b) {
    // CSI
    while (i < text.length) {
      if (_isCsiFinal(text.codeUnitAt(i++))) break;
    }
  } else if (kind == 0x5d ||
      kind == 0x9d || // OSC
      kind == 0x50 ||
      kind == 0x90 || // DCS
      kind == 0x58 ||
      kind == 0x98 || // SOS
      kind == 0x5e ||
      kind == 0x9e || // PM
      kind == 0x5f ||
      kind == 0x9f) {
    // APC
    while (i < text.length) {
      final c = text.codeUnitAt(i++);
      if (c == 0x9c || (c == 0x07 && (kind == 0x5d || kind == 0x9d))) break;
      if (c == 0x1b && i < text.length && text.codeUnitAt(i) == 0x5c) {
        i++;
        break;
      }
    }
  } else if (kind >= 0x20 && kind <= 0x2f) {
    while (i < text.length &&
        text.codeUnitAt(i) >= 0x20 &&
        text.codeUnitAt(i) <= 0x2f) {
      i++;
    }
    if (i < text.length) i++; // charset/designation final byte
  }
  return i;
}

bool _isCsiFinal(int c) => c >= 0x40 && c <= 0x7E;
