import 'dart:async';
import 'dart:typed_data';

import '../rect.dart';

import 'backend_surface.dart';

/// Abstract interface for terminal rendering backends.
///
/// Encapsulates all low-level terminal encoding (ANSI escape sequences,
/// notcurses API calls, etc.) behind a uniform API. [Screen] delegates
/// positioning, erasing, and writing to a [TerminalBackend], keeping
/// layout logic and clipping in Screen itself.
///
/// Operations are batched: callers build up a sequence of
/// [moveCursor]/[eraseCells]/[writeText] calls, then call [flush] to send
/// them to the terminal. This lets ANSI backends emit one batched string
/// and notcurses backends call render() once.
abstract class TerminalBackend {
  /// Begin a logical frame. Flush requests made before the matching
  /// [endFrame] are coalesced into one presentation.
  void beginFrame() {}

  /// End a logical frame and present accumulated mutations once.
  void endFrame() => flush();

  /// Move the logical cursor to ([row], [col]), 0-indexed.
  void moveCursor(int row, int col);

  /// Set the hardware cursor's final presentation position.
  ///
  /// Unlike [moveCursor], this is not a drawing operation. Retained-mode
  /// backends must keep this target independent from rows mutated by chat,
  /// panels, or animations.
  void parkCursor(int row, int col) => moveCursor(row, col);

  /// Erase [n] cells starting at ([row], [col]).
  ///
  /// The cursor position after this call is ([row], [col]).
  void eraseCells(int row, int col, int n);

  /// Write [text] at the current cursor position, advancing the cursor
  /// by the printable width of [text].
  void writeText(String text);

  /// Save the current cursor position.
  void saveCursor();

  /// Restore the previously saved cursor position.
  void restoreCursor();

  /// Flush any buffered operations to the terminal.
  void flush();

  /// Enter the alternate screen buffer.
  void enterAltScreen();

  /// Leave the alternate screen buffer.
  void leaveAltScreen();

  /// Enable terminal bracketed paste mode (DECSET 2004) so the terminal
  /// wraps every paste in `ESC[200~`…`ESC[201~` markers. Called on entering
  /// the alternate screen.
  void enableBracketedPaste();

  /// Disable bracketed paste mode (DECRST 2004). Called on leaving the
  /// alternate screen so the terminal returns to its default behavior.
  void disableBracketedPaste();

  /// Whether the backend supports color output.
  bool get supportsColor;

  /// Wrap [text] with color escape codes when color is supported.
  ///
  /// [code] is the SGR parameter (e.g. `'31'` for red foreground).
  String colorize(String code, String text);

  /// Stream of raw input bytes from the terminal.
  Stream<List<int>> get stdin;

  /// Number of columns in the terminal, or a sensible default.
  int get terminalColumns;

  /// Render a decoded image at absolute ([row], [col]), clipped to [maxCols]
  /// cells wide.  [rgba] is a 32-bit-per-pixel RGBA buffer, [width]×[height]
  /// pixels.  The caller pre-fits to the available cell budget; the backend
  /// picks pixel-protocol vs rasterized-block fallback according to terminal
  /// capability.  ANSI backends that cannot emit pixels draw a one-cell
  /// placeholder so the method stays total.
  ///
  /// Coordinates are absolute (standard-plane) unless [targetSurface] is
  /// supplied: when it is a chat child plane, the image is blitted as a child
  /// plane parented to that surface's plane, so it stacks ABOVE the focused
  /// chat surface (but below the input/overlay planes the coordinator keeps on
  /// top).  Used to render `/image` and `render_image` over a streaming panel
  /// without the chat content obscuring the picture.
  void renderImageAbsolute({
    required int row,
    required int col,
    required Uint32List rgba,
    required int width,
    required int height,
    required int maxCols,
    BackendSurface? targetSurface,
  });

  /// Create a bounded [BackendSurface] for an independent drawable area.
  ///
  /// Used by [Panel] to obtain a surface it can write to at relative
  /// coordinates, move, resize, and z-order. Coordinates passed to the
  /// returned surface's `putAt`/`eraseAt` are relative to [bounds].
  BackendSurface createSurface(Rect bounds);

  /// Whether chat writes coalesce into delayed, timer-bounded presents (true
  /// for retained-mode backends like notcurses; false for the synchronous ANSI
  /// path, which paints each write immediately). The chat region's
  /// [_coalescePaints] and the presentation scheduler's [requestChatPresentation]
  /// key off this to choose between the synchronous and scheduled paint paths.
  bool get coalescesPaints;
}
