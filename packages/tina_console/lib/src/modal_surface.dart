import 'input_event.dart';

/// A keyboard-driven overlay that wants first claim on input while it is open.
///
/// Implemented by modal UI components (e.g. the tool-output panel) and
/// registered with [LineEditor.registerModal] so they can intercept keys
/// without the editor growing a feature-specific setter for each one. While a
/// registered surface's [isActive] is `true`, [LineEditor._dispatchEvent]
/// offers it every event *before* the focus manager, menu bar, focused panel,
/// or the editor itself — so an open modal can capture navigation and dismiss
/// keys (arrows, Esc) that those layers would otherwise consume.
///
/// When [isActive] is `false`, or after [handleEvent] returns `false`, the
/// event falls through to normal dispatch unchanged.
abstract class ModalSurface {
  /// Whether this surface currently wants to consume input.
  bool get isActive;

  /// Handle [event]. Return `true` if consumed (the editor should not process
  /// it further), `false` if the event should fall through to the next handler.
  bool handleEvent(InputEvent event);
}
