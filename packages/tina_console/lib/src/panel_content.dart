import 'backend/backend_surface.dart';
import 'rect.dart';
import 'region.dart';

/// Anything that can be presented inside a [PanelFrame]'s interior.
///
/// Today the only implementation wraps a [ScrollingTextRegion] (a conversation's
/// chat). Future panels — a file browser, a diff view, logs — will implement
/// this to reuse the same border/focus/busy chrome without being tied to a
/// conversation or to chat-specific positioning math.
abstract interface class PanelContent {
  /// Position yourself within [interior] (already inset by the frame's border).
  /// When [reserveInputRow] is true, keep the bottom interior row free for the
  /// shared input line.
  void fit(Rect interior, {required bool reserveInputRow});

  /// Attach your backing surface to the screen (make content visible).
  void attach();

  /// Detach your backing surface from the screen (make content invisible without
  /// discarding buffered state).
  void detach();

  /// Whether the content is currently detached from the screen. The chat
  /// adapter overrides it; non-chat panels are never detached (default false).
  bool get isDetached => false;

  /// The backing surface, for callers that parent overlays (e.g. image
  /// rendering) onto this content's plane. null when the content has no surface
  /// (default — non-chat panels). The chat adapter overrides it.
  BackendSurface? get surface => null;

  /// Borrow [s] as this content's canvas, making the owning frame the single
  /// source of geometry (the frame-owns-canvas model). null (the default)
  /// returns the content to managing its own surface. The chat adapter
  /// overrides it; non-chat content ignores the surface it's given.
  void bindSurface(BackendSurface? s) {}

  /// Repaint the content in place, without changing geometry. For callers
  /// that blanked the screen over this panel (a full-screen overlay scrim on
  /// backends without real z-order).
  void repaint() {}
}

/// Adapts a [ScrollingTextRegion] (chat) to [PanelContent].
///
/// This is the seam that decouples [PanelFrame] (chrome) from the conversation
/// it presents: the frame knows only rectangles and focus, while this adapter
/// owns the chat-specific positioning (bounds + input-row reservation).
class ChatRegionPanelContent implements PanelContent {
  ChatRegionPanelContent(this._chat);
  final ScrollingTextRegion _chat;

  /// The underlying chat surface, for callers that need to parent overlays
  /// (e.g. image rendering) onto this panel's chat plane.
  @override
  BackendSurface? get surface => _chat.surface;

  /// Whether the wrapped region is currently detached from the screen.
  @override
  bool get isDetached => _chat.isDetached;

  @override
  void fit(Rect interior, {required bool reserveInputRow}) {
    // These three calls are ATOMIC — together they are the history-preservation
    // invariant: input reservation is a display-only shift (a bottom inset), not
    // a buffer resize, so cycling focus away and back does not drop scrollback.
    // Never split them, and never let a caller toggle just one of them.
    //
    // Order matters: setBoundsOverride must run before setBottomInset so the
    // surface is sized to the NEW bounds. (setBottomInset early-returns when the
    // inset is unchanged — e.g. a move with no focus toggle — so it cannot be
    // relied on to reposition the surface; setBoundsOverride does that.)
    if (_chat.hasBoundSurface) {
      // Frame-owns-canvas: the frame sizes the surface to the content rect
      // (interior minus the input row when reserved), so the inset is
      // structural and _bottomInset stays 0 — calling setBottomInset would
      // double-subtract and waste a row. Bounds flow from the surface;
      // setBoundsOverride only reconciles the buffer and re-emits on geometry
      // changes. (reserveInputRow is set once at bind for spawned panels and
      // never toggled, so this never shrinks the buffer mid-session.)
      _chat.setBoundsOverride(interior);
      _chat.keepBottomInset = reserveInputRow;
      return;
    }
    _chat.setBoundsOverride(interior);
    _chat.setBottomInset(reserveInputRow ? 1 : 0);
    _chat.keepBottomInset = reserveInputRow;
  }

  @override
  void attach() => _chat.attach();

  @override
  void detach() => _chat.detach();

  @override
  void bindSurface(BackendSurface? s) => _chat.bindSurface(s);

  @override
  void repaint() => _chat.repaint();
}
