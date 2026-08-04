import 'input_event.dart';
import 'rect.dart';

/// Something that can receive keyboard focus and consume input events.
///
/// Implemented by [Panel] and (via a thin `implements Focusable` seam) by
/// existing components like `ChatRegion` and `MenuBar` so the same focus ring
/// can shuttle between them. A [FocusManager] owns the ring and routes events
/// to whichever [Focusable] currently has focus.
abstract class Focusable {
  /// Whether this focusable currently holds focus.
  bool get hasFocus;

  /// Whether this focusable is eligible to receive focus right now. Defaults to
  /// `true`; a component that is hidden, disabled, or empty can report `false`
  /// and the focus ring will skip over it.
  bool get canFocus => true;

  /// Absolute screen rectangle occupied by this focusable. Used by
  /// [FocusManager.focusInDirection] to pick the nearest neighbor in a given
  /// direction. Returning [Rect.empty] takes this focusable out of spatial
  /// navigation while still allowing ring cycling via Tab.
  Rect get bounds;

  /// Grant focus. Implementations should update [hasFocus] and re-render any
  /// focus indication (e.g. a highlighted border).
  void focus();

  /// Release focus. Implementations should update [hasFocus] and re-render.
  void blur();

  /// Mark this panel as the cycling highlight — the panel being navigated to
  /// while the focus ring is in cycling mode (not yet committed as the focus).
  /// Default no-op; panels that show a distinct cycling cue override this. A
  /// panel is never both focused and highlighted at once.
  void highlight() {}

  /// Clear the cycling highlight. Default no-op.
  void unhighlight() {}

  /// Attempt to handle [event]. Returns `true` if consumed (the host should not
  /// process it further), `false` if the event should fall through to the next
  /// handler (typically the line editor).
  bool handleEvent(InputEvent event);
}
