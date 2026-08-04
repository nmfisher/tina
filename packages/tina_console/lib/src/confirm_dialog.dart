import 'rect.dart';
import 'region.dart';
import 'screen.dart';

/// "Ctrl+C again to exit" confirmation box.
///
/// Owns an [OverlayRegion]; the host calls [trigger] on the first Ctrl-C
/// (with an empty buffer) and [dismiss] on any other input. [render] shows
/// the dialog; [reset] clears it for a new readLine session.
class ConfirmDialog {
  final Screen _screen;
  late OverlayRegion _overlay;

  bool _confirmQuit = false;

  ConfirmDialog(this._screen) {
    _overlay = OverlayRegion(_screen, _defaultBounds(_screen));
  }

  bool get isVisible => _confirmQuit;

  /// Called on Ctrl-C with an empty buffer. Returns `true` if this is the
  /// second press in a row (host should exit).
  bool trigger() {
    if (_confirmQuit) return true;
    _confirmQuit = true;
    render();
    return false;
  }

  /// Reset trigger state on any other input. Erases the dialog if shown.
  void dismiss() {
    if (!_confirmQuit) return;
    _confirmQuit = false;
    _overlay.hide();
  }

  void reset() {
    _confirmQuit = false;
    _overlay.hide();
  }

  void render() {
    if (!_confirmQuit) return;
    _overlay.reposition(_defaultBounds(_screen));
    _overlay.show(_lines());
  }

  void dispose() {
    _overlay.dispose();
  }

  static Rect _defaultBounds(Screen screen) {
    final layout = screen.layout;
    final w = _innerWidth + 2; // box width including borders
    const h = 3;
    final centerRow = (layout.height - h) ~/ 2;
    // Centre horizontally within the chat region in split mode; centre on
    // the whole terminal otherwise.
    final hostCol = layout.isSplit ? layout.chat.col : 0;
    final hostWidth = layout.isSplit ? layout.chat.width : layout.width;
    final col = hostCol + ((hostWidth - w) ~/ 2).clamp(0, hostWidth);
    return Rect(row: centerRow, col: col, width: w, height: h);
  }

  static const String _msg = ' Ctrl+C again to exit ';
  static int get _innerWidth => _msg.length;

  List<String> _lines() {
    final hLine = '─' * _innerWidth;
    final useColor = _screen.ansi.useColor;
    String wrap(String s) =>
        useColor ? _screen.colorize(_screen.theme.dialog.confirm, s) : s;
    return [
      wrap('┌$hLine┐'),
      wrap('│$_msg│'),
      wrap('└$hLine┘'),
    ];
  }
}
