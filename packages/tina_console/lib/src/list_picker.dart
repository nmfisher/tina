import '../tina_console.dart';

/// One row of a [ListPicker]: a label plus an optional dim detail carried
/// on the same line (a timestamp prefix, for example).
final class ListPickerItem {
  const ListPickerItem(this.label, {this.detail});

  /// Main text, clipped to the dialog width by the picker.
  final String label;

  /// Optional leading detail rendered dim before the label.
  final String? detail;
}

/// A minimal modal list picker: title, focus-marked rows, Enter selects,
/// Escape cancels. No filtering, no grouping — the caller owns ordering
/// and numbering. Driven by an injectable [readEvent] like the other
/// overlays, so tests can drive it headlessly.
Future<int?> runListPickerOverlay({
  required Screen screen,
  required String title,
  required List<ListPickerItem> items,
  required Future<InputEvent> Function() readEvent,
  String? contextLine,
  String footer = '↑↓ move · Enter select · Esc cancel',
  String? accent,
}) async {
  if (items.isEmpty) return null;
  return _ListPicker(
    screen: screen,
    title: title,
    items: items,
    readEvent: readEvent,
    contextLine: contextLine,
    footer: footer,
    accent: accent,
  ).run();
}

class _ListPicker {
  _ListPicker({
    required Screen screen,
    required String title,
    required List<ListPickerItem> items,
    required Future<InputEvent> Function() readEvent,
    required this.contextLine,
    required this.footer,
    required this.accent,
  })  : _screen = screen,
        _title = title,
        _items = items,
        _readEvent = readEvent;

  final Screen _screen;
  final String _title;
  final List<ListPickerItem> _items;
  final Future<InputEvent> Function() _readEvent;
  final String? contextLine;
  final String footer;
  final String? accent;

  static const _focusMark = '▸';

  late OverlayRegion _overlay;
  late Rect _rect;
  int _focus = 0;
  int _scroll = 0;
  bool _open = false;
  int? _selected;

  void repaint() {
    if (_open) _render();
  }

  Future<int?> run() async {
    _overlay = OverlayRegion(_screen, Rect.empty);
    final cursor = _screen.claimCursor();
    _open = true;
    try {
      _render();
      while (true) {
        final ev = await _readEvent();
        if (ev is EscapeKey ||
            (ev is ControlKey && ev.code == ControlCode.ctrlC)) return null;
        if (_dispatch(ev)) return _selected;
        _render();
      }
    } finally {
      _open = false;
      _overlay.hide();
      _overlay.dispose();
      cursor.release();
    }
  }

  bool _dispatch(InputEvent ev) {
    if (ev is ControlKey && ev.code == ControlCode.enter) {
      _selected = _focus;
      return true;
    }
    if (ev is! ArrowKey) return false;
    final page = _visibleRows;
    switch (ev.direction) {
      case ArrowDirection.up:
        _focus = (_focus - 1).clamp(0, _items.length - 1);
      case ArrowDirection.down:
        _focus = (_focus + 1).clamp(0, _items.length - 1);
      case ArrowDirection.pageUp:
        _focus = (_focus - page).clamp(0, _items.length - 1);
      case ArrowDirection.pageDown:
        _focus = (_focus + page).clamp(0, _items.length - 1);
      case ArrowDirection.left:
      case ArrowDirection.right:
        break;
    }
    return false;
  }

  /// Item rows that fit: the box's body holds `height - 4` lines and the
  /// context line, when present, spends one of them.
  int get _visibleRows =>
      (_rect.height - 4 - (contextLine == null ? 0 : 1)).clamp(1, 1 << 30);

  void _render() {
    final area = dialogArea(_screen.layout);
    final width = area.width < 56 ? area.width : (area.width - 8).clamp(0, 76);
    final height = (area.height * 2 ~/ 3)
        .clamp(area.height < 12 ? area.height : 12, area.height);
    _rect = Rect(
      row: area.row + (area.height - height) ~/ 2,
      col: area.col + (area.width - width) ~/ 2,
      width: width,
      height: height,
    );
    if (_focus < _scroll) _scroll = _focus;
    if (_focus >= _scroll + _visibleRows) _scroll = _focus - _visibleRows + 1;
    _overlay.update(
      bounds: _rect,
      lines: dialogBoxLines(
        width: _rect.width,
        height: _rect.height,
        title: _title,
        body: _body(_rect.width - 4),
        footer: footer,
        paint: _paint,
      ),
    );
  }

  String _paint(String s) {
    final tint = accent; // local copy so the null check promotes
    return tint == null ? s : _screen.colorize(tint, s);
  }

  List<String> _body(int innerW) {
    final out = <String>[
      if (contextLine != null) clipToVisibleColumns(contextLine!, innerW),
    ];
    for (var i = _scroll;
        i < _items.length && out.length < _visibleRows + 1;
        i++) {
      final item = _items[i];
      final detail = item.detail == null ? '' : '${_dim(item.detail!)}  ';
      final text = clipToVisibleColumns('$detail${item.label}', innerW - 4);
      out.add(i == _focus ? '  $_focusMark ${_accentText(text)}' : '    $text');
    }
    return out;
  }

  String _dim(String s) => _screen.colorize(_screen.theme.chat.dim, s);
  String _accentText(String s) => _screen.colorize(accent ?? 'cyan', s);
}
