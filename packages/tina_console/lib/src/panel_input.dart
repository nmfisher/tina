import 'focusable.dart';

/// How a panel participates in the application's keyboard routing.
enum PanelInputMode {
  /// Unhandled keys edit the active conversation's shared input line.
  sharedEditor,

  /// The panel provides its own commands; application navigation and interrupt
  /// keys retain their usual behavior. No shared input row is reserved.
  readOnly,

  /// All input belongs to the panel, including Escape and Ctrl+C. Ctrl+G is
  /// reserved for focus navigation. Prompts and modal overlays take priority.
  /// Unhandled events are dropped rather than leaking into the chat editor.
  exclusive,
}

/// Optional capability of a Focusable; ordinary widgets need not implement it.
abstract interface class PanelInputTarget implements Focusable {
  PanelInputMode get inputMode;
}
