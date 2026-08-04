import 'input_event.dart';
import 'panel.dart';
import 'rect.dart';
import 'screen.dart';

/// A minimal concrete [Panel]: a framed box showing static lines of text.
///
/// Draws a thin border with a [title] and the supplied content lines. Focus
/// is reflected as a color change on the border only — no line-weight swap,
/// no cursor row highlight, no arrow-key navigation. The panel is a passive
/// info surface; it consumes plain typing so keystrokes don't leak into the
/// line editor while it holds focus, and lets Ctrl+C / Ctrl+D through so
/// quit-style shortcuts stay reachable.
class TextPanel extends Panel {
  final String title;
  List<String> _content = const [];

  TextPanel(Screen screen, Rect bounds, {this.title = ''}) : super(screen, bounds);

  /// Replace the displayed content lines and repaint.
  void setContent(List<String> lines) {
    _content = List<String>.unmodifiable(lines);
    render();
  }

  /// Rebuild [rows] from the frame + content and repaint.
  void render() {
    _buildRows();
    redraw();
  }

  @override
  void resize(int width, int height) {
    super.resize(width, height);
    render(); // rebuild the frame for the new geometry
  }

  /// Usable content rows (excludes top and bottom borders).
  int get innerHeight => bounds.height >= 2 ? bounds.height - 2 : 0;

  /// Usable content columns (excludes side borders and padding).
  int get innerWidth => bounds.width >= 4 ? bounds.width - 4 : 0;

  void _buildRows() {
    if (bounds.height < 2 || bounds.width < 2) {
      for (var i = 0; i < rows.length; i++) {
        rows[i] = '';
      }
      return;
    }
    // Thin border everywhere; color is the only focus cue. Line-weight
    // swaps (heavy vs thin) were removed at the user's request — the frame
    // is now stable across focus changes, which reads as less busy.
    const hLine = '─';
    const vLine = '│';
    const tl = '┌';
    const tr = '┐';
    const bl = '└';
    const br = '┘';
    final accent = hasFocus
        ? screen.theme.textPanel.focused
        : screen.theme.textPanel.unfocused; // cyan when focused, dim otherwise
    final c = screen.colorize;

    // Top border with title: ┌─ TITLE ───┐. Falls back to a plain border
    // when there's no title or the title doesn't fit.
    final label = title.isEmpty ? '' : ' $title ';
    final String topBorder;
    if (label.isEmpty || label.length > bounds.width - 3) {
      topBorder = '$tl${hLine * (bounds.width - 2)}$tr';
    } else {
      final fill = hLine * (bounds.width - 3 - label.length);
      topBorder = '$tl$hLine$label$fill$tr';
    }
    rows[0] = c(accent, topBorder);

    // Middle rows: │ content │
    final innerH = innerHeight;
    final innerW = innerWidth;
    for (var r = 0; r < innerH; r++) {
      var line = r < _content.length ? _content[r] : '';
      line = _clip(line, innerW);
      line = line.padRight(innerW);
      rows[1 + r] = c(accent, vLine) + ' ' + line + ' ' + c(accent, vLine);
    }

    // Bottom border: └──────┘
    rows[bounds.height - 1] = c(accent, '$bl${hLine * (bounds.width - 2)}$br');
  }

  String _clip(String s, int maxCols) {
    if (maxCols <= 0) return '';
    final out = StringBuffer();
    var visible = 0;
    var i = 0;
    while (i < s.length && visible < maxCols) {
      final ch = s[i];
      // Skip embedded ANSI when measuring width, but keep it in output.
      if (ch == '\x1b' && i + 1 < s.length && s[i + 1] == '[') {
        var j = i + 2;
        while (j < s.length &&
            (s.codeUnitAt(j) < 0x40 || s.codeUnitAt(j) > 0x7e)) {
          j++;
        }
        if (j < s.length) j++;
        out.write(s.substring(i, j));
        i = j;
        continue;
      }
      out.write(ch);
      visible++;
      i++;
    }
    return out.toString();
  }

  @override
  void onFocusChanged() => render();

  @override
  bool handleEvent(InputEvent event) {
    switch (event) {
      case CharInput():
      case ArrowKey():
      case EditingKey():
      case AltKey():
      case FunctionKey():
        // Passive info surface — swallow input so nothing leaks into the
        // line editor while the panel is focused. Ctrl+Arrow was already
        // handled upstream by the FocusManager for spatial nav.
        return true;
      case ControlKey(:final code):
        // Let quit/cancel keys fall through to the editor/host.
        if (code == ControlCode.ctrlC || code == ControlCode.ctrlD) return false;
        return true;
      default:
        return false;
    }
  }
}
