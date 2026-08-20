import 'focusable.dart';
import 'input_event.dart';
import 'rect.dart';
import 'screen.dart';

/// Static content in the right-hand info box.
///
/// The [Screen] paints the info box's border in [Screen.redrawFrame]; this
/// panel writes text into the box's interior ([ScreenLayout.info]) and
/// participates in the focus ring so [FocusManager] can steer Ctrl+Arrow
/// navigation to and from it. It has no border of its own (would double up
/// with the frame) and no scroll or cursor state — it's a passive info
/// surface, matching the behavior we settled on for the old TextPanel.
class InfoPanel implements Focusable {
  final Screen screen;
  final String title;
  List<String> _content;
  bool _hasFocus = false;
  bool _visible = true;

  /// Whether a visible [render] has actually painted since the last hide.
  /// Guards [hide]'s blanking: a panel that never drew anything (e.g. the
  /// session bar on a resumed session with spawned panels — hidden by its
  /// first refresh, before it ever rendered) must not erase the info column,
  /// which would wipe pixels that spawned panels already own.
  bool _painted = false;

  InfoPanel(this.screen, {this.title = '', List<String> content = const []})
      : _content = List<String>.unmodifiable(content);

  /// Replace the displayed content and repaint.
  void setContent(List<String> lines) {
    _content = List<String>.unmodifiable(lines);
    render();
  }

  /// Hide the panel — blanks the interior. Retains content so [show]
  /// restores it as-is. Skips the blanking when the panel never painted
  /// (see [_painted]) so a first-refresh hide can't erase content another
  /// surface (restored spawned panels) already owns.
  void hide() {
    if (!_visible) return;
    _visible = false;
    if (!_painted) return;
    _clearInterior();
    _painted = false;
  }

  /// Show the panel — repaints retained content.
  void show() {
    if (_visible) return;
    _visible = true;
    render();
  }

  bool get isVisible => _visible;

  // -- Focusable ---------------------------------------------------------

  @override
  bool get hasFocus => _hasFocus;

  @override
  bool get canFocus => _visible && !bounds.isEmpty;

  @override
  Rect get bounds => screen.layout.info;

  @override
  void focus() {
    _hasFocus = true;
    screen.focusFrame(FrameBox.info);
  }

  @override
  void blur() {
    _hasFocus = false;
    // Tint cleared by the new focus's focusFrame().
  }

  @override
  void highlight() => screen.highlightFrame(FrameBox.info);

  @override
  void unhighlight() => screen.highlightFrame(null);

  @override
  bool handleEvent(InputEvent event) {
    switch (event) {
      case CharInput():
      case ArrowKey():
      case EditingKey():
      case AltKey():
      case FunctionKey():
        // Passive surface — swallow so nothing leaks into the line editor.
        return true;
      case ControlKey(:final code):
        // Quit/cancel keys still fall through to the host.
        if (code == ControlCode.ctrlC || code == ControlCode.ctrlD) return false;
        return true;
      default:
        return false;
    }
  }

  // -- Rendering ---------------------------------------------------------

  /// Paint the panel's content into [Screen.info] at a steady dim style.
  /// Focus is signaled by the box border, which [Screen] tints cyan via
  /// [Screen.repaintInfoFrame] on focus/blur — not by the content itself.
  void render() {
    final b = bounds;
    if (b.isEmpty) return;
    if (!_visible) {
      _clearInterior();
      return;
    }
    final accent = screen.theme.infoPanel.dim; // dim — the box border carries the focus cue
    _painted = true;
    var row = b.row;
    if (title.isNotEmpty && b.height > 0) {
      final label = screen.colorize(accent, title);
      _writeLine(row, b.col, label, b.width);
      row++;
    }
    for (var i = 0; row < b.row + b.height; i++, row++) {
      final line = i < _content.length ? _content[i] : '';
      final tinted = line.isEmpty ? '' : screen.colorize(accent, line);
      _writeLine(row, b.col, tinted, b.width);
    }
  }

  void _writeLine(int row, int col, String text, int maxCols) {
    screen.putAtAbsolute(
      row: row,
      col: col,
      text: text,
      maxCols: maxCols,
      moveCursor: false,
    );
  }

  void _clearInterior() {
    final b = bounds;
    if (b.isEmpty) return;
    for (var r = b.row; r < b.row + b.height; r++) {
      screen.eraseAtAbsolute(row: r, col: b.col, n: b.width, moveCursor: false);
    }
  }
}
