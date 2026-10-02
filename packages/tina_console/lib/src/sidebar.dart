import 'dart:async';
import 'rect.dart';

/// Shared space for session-owned, focusable inspector panels. Plugins request
/// a size; the frontend stacks them without knowledge of their content.
final class SidebarLayout {
  SidebarLayout(this.viewport);
  final Rect Function() viewport;
  final _panels = <SidebarPanel>[];
  int _serial = 0;
  bool _scheduled = false;
  bool get isEmpty => _panels.isEmpty;

  SidebarPanel register(void Function() repaint, {int priority = 100}) {
    final panel = SidebarPanel._(this, repaint, priority, ++_serial);
    _panels.add(panel);
    _changed();
    return panel;
  }

  void _changed() {
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      for (final panel in _panels.toList()) {
        if (!panel._closed) panel._repaint();
      }
    });
  }

  Rect _bounds(SidebarPanel target) {
    final chat = viewport();
    if (chat.width < 8 || chat.height < 4 || target._closed) return Rect.empty;
    final panels = _panels.where((p) => p._height > 0).toList()
      ..sort((a, b) => a._focused == b._focused
          ? a._priority == b._priority
              ? a._serial.compareTo(b._serial)
              : a._priority.compareTo(b._priority)
          : a._focused
              ? -1
              : 1);
    // Below four rows a bordered panel has no usable content. Keep the higher
    // priority panels when even those minimums do not fit.
    final visible = panels.take(chat.height ~/ 4).toList();
    if (!visible.contains(target)) return Rect.empty;
    final heights = {for (final p in visible) p: 4};
    var remaining = chat.height - visible.length * 4;
    while (remaining > 0) {
      var grew = false;
      for (final p in visible) {
        if (remaining > 0 && heights[p]! < p._height) {
          heights[p] = heights[p]! + 1;
          remaining--;
          grew = true;
        }
      }
      if (!grew) break;
    }
    var row = chat.row;
    for (final p in visible) {
      final height = heights[p]!;
      if (identical(p, target)) {
        final width = p._width.clamp(8, chat.width);
        return Rect(
            row: row,
            col: chat.right - width + 1,
            width: width,
            height: height);
      }
      row += height;
    }
    return Rect.empty;
  }
}

final class SidebarPanel {
  SidebarPanel._(this._layout, this._repaint, this._priority, this._serial);
  final SidebarLayout _layout;
  final void Function() _repaint;
  final int _priority;
  final int _serial;
  int _height = 0, _width = 44;
  bool _closed = false;
  bool _focused = false;
  Rect get bounds => _layout._bounds(this);
  void requestSize(
      {required int height, int width = 44, bool focused = false}) {
    if (_closed) return;
    final h = height == 0 ? 0 : height.clamp(4, 10000),
        w = width.clamp(8, 10000);
    if (_height == h && _width == w && _focused == focused) return;
    _height = h;
    _width = w;
    _focused = focused;
    _layout._changed();
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    _layout._panels.remove(this);
    _layout._changed();
  }
}
