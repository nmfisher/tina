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
  /// [relCol]). The caller pre-clips to its own width; the backend may clip
  /// again. ANSI escapes in [text] are preserved but don't consume columns.
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

/// Clip [s] to a maximum of [maxCols] visible columns, preserving any embedded
/// ANSI (CSI) escape sequences without counting them toward the budget.
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
    if (s[i] == '\x1b') {
      sb.write(s[i]);
      i++;
      if (i < s.length && s[i] == '[') {
        sb.write(s[i]);
        i++;
        while (i < s.length && !_isCsiFinal(s.codeUnitAt(i))) {
          sb.write(s[i]);
          i++;
        }
        if (i < s.length) {
          sb.write(s[i]);
          i++;
        }
      } else if (i < s.length) {
        sb.write(s[i]);
        i++;
      }
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

bool _isCsiFinal(int c) => c >= 0x40 && c <= 0x7E;
