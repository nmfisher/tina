/// Semantic input events produced by [InputParser].
///
/// Raw terminal bytes are decoded into these events, decoupling byte-level
/// parsing (ESC sequences, UTF-8) from the editing actions they trigger.
sealed class InputEvent {}

/// One or more printable characters (completed UTF-8 decode).
class CharInput extends InputEvent {
  final String text;
  CharInput(this.text);

  @override
  String toString() =>
      'CharInput(${text.length == 1 ? '0x${text.codeUnitAt(0).toRadixString(16)}' : '"$text"'})';

  @override
  bool operator ==(Object other) =>
      other is CharInput && text == other.text;

  @override
  int get hashCode => text.hashCode;
}

/// A control key that doesn't produce a printable character.
class ControlKey extends InputEvent {
  final ControlCode code;
  ControlKey(this.code);

  @override
  bool operator ==(Object other) =>
      other is ControlKey && code == other.code;

  @override
  int get hashCode => code.hashCode;
}

/// A mouse scroll wheel notch. Routed to the focused panel's scrollback
/// (conversation panels and run panels scroll their chat) — never to the
/// editor, so the wheel can't be confused with command-history arrows.
class ScrollEvent extends InputEvent {
  /// True = wheel up (scroll back into history), false = wheel down.
  final bool up;
  ScrollEvent({required this.up});

  @override
  String toString() => 'ScrollEvent(${up ? 'up' : 'down'})';

  @override
  bool operator ==(Object other) =>
      other is ScrollEvent && other.up == up;

  @override
  int get hashCode => up.hashCode;
}

/// An arrow key (CSI A/B/C/D). [hasCtrl] is true for Ctrl+Arrow (used by
/// [FocusManager] to steer spatial navigation inside the focus ring);
/// [hasAlt] is true for Alt+Arrow. When either modifier is set, the line
/// editor moves by word instead of by character.
class ArrowKey extends InputEvent {
  final ArrowDirection direction;
  final bool hasCtrl;
  final bool hasAlt;
  ArrowKey(this.direction, {this.hasCtrl = false, this.hasAlt = false});

  @override
  String toString() =>
      'ArrowKey($direction${hasCtrl ? ' +ctrl' : ''}${hasAlt ? ' +alt' : ''})';

  @override
  bool operator ==(Object other) =>
      other is ArrowKey &&
      direction == other.direction &&
      hasCtrl == other.hasCtrl &&
      hasAlt == other.hasAlt;

  @override
  int get hashCode => Object.hash(direction, hasCtrl, hasAlt);
}

/// An editing key (Home, End, Delete, KillToEnd, KillToStart).
class EditingKey extends InputEvent {
  final EditingAction action;
  EditingKey(this.action);

  @override
  String toString() => 'EditingKey($action)';

  @override
  bool operator ==(Object other) =>
      other is EditingKey && action == other.action;

  @override
  int get hashCode => action.hashCode;
}

/// Alt + letter key combination (ESC followed by a printable character).
class AltKey extends InputEvent {
  /// Lowercase code unit of the letter pressed with Alt.
  final int letter;
  AltKey(this.letter);

  @override
  String toString() =>
      'AltKey(0x${letter.toRadixString(16)}/${String.fromCharCode(letter)})';

  @override
  bool operator ==(Object other) =>
      other is AltKey && letter == other.letter;
  @override
  int get hashCode => letter.hashCode;
}

/// A function key (F1–F12).
class FunctionKey extends InputEvent {
  final FunctionKeyCode code;
  FunctionKey(this.code);

  @override
  bool operator ==(Object other) =>
      other is FunctionKey && code == other.code;
  @override
  int get hashCode => code.hashCode;
}

/// Standalone ESC press (not part of a CSI/SS3 sequence).
class EscapeKey extends InputEvent {
  @override
  String toString() => 'EscapeKey';
}

/// An unrecognized escape sequence, delivered raw for passthrough.
class UnknownEscape extends InputEvent {
  final List<int> bytes;
  UnknownEscape(this.bytes);
}

/// The complete payload of a bracketed-paste (`ESC[200~` … `ESC[201~`)
/// delivered as a single unit, so the line editor can show a compact
/// placeholder instead of a flood of per-character input. The text retains
/// any embedded newlines/tabs/controls; on submit it is sent verbatim.
class PasteInput extends InputEvent {
  final String text;
  PasteInput(this.text);

  @override
  bool operator ==(Object other) =>
      other is PasteInput && text == other.text;

  @override
  int get hashCode => text.hashCode;

  @override
  String toString() => 'PasteInput(${text.runes.length} chars)';
}

/// Control key codes.
enum ControlCode {
  ctrlC,
  ctrlD,
  ctrlL,
  /// Ctrl+W (ETB, 0x17). Used as the FocusManager's enter/exit toggle.
  /// Portable at the byte level, but two known collisions the caller
  /// should be aware of: readline binds it to delete-word-backward
  /// (users' muscle memory), and VSCode / JetBrains integrated terminals
  /// intercept it before the process sees the byte.
  ctrlW,
  /// Ctrl+G (BEL, 0x07). A second FocusManager enter/exit key, for
  /// environments that swallow Ctrl+W before the process sees it. Ctrl+G is
  /// rarely bound by terminals or IDEs and isn't a tty signal in raw mode,
  /// so it reliably reaches the process. Functionally identical to Ctrl+W.
  ctrlG,
  /// Ctrl+S (DC3, 0x13). Used by the prompts overlay as "save". Raw mode
  /// disables XON/XOFF flow control so the byte reaches the process; a few
  /// terminals still intercept it before the process does.
  ctrlS,
  /// Ctrl+O (SI, 0x0F). The panel-maximize toggle. Not a tty signal in raw
  /// mode, but macOS' line discipline still eats it as the VDISCARD toggle
  /// (IEXTEN) — DiscardUnbinder unbinds that char right after notcurses
  /// init, and Linux has no VDISCARD, so the byte reaches the process.
  ctrlO,
  enter,
  tab,
  backspace,
}

/// Arrow key directions.
enum ArrowDirection {
  up,
  down,
  left,
  right,
  pageUp,
  pageDown,
}

/// Editing actions from CSI sequences and control keys.
enum EditingAction {
  home,
  end,
  delete,
  killToEnd,
  killToStart,
  deleteWordBackward,
  deleteWordForward,
}

/// Function key codes.
enum FunctionKeyCode {
  f1,
  f2,
  f3,
  f4,
  f5,
  f6,
  f7,
  f8,
  f9,
  f10,
  f11,
  f12,
}
