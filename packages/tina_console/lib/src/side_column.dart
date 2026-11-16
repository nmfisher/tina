import 'dart:async';

import 'rect.dart';
import 'screen_layout.dart';
import 'sidebar.dart';

/// Fixed top-to-bottom order of the side column's panels.
abstract final class SideColumnRank {
  /// The classifier inspector.
  static const int classifier = 0;

  /// The plans tree.
  static const int plans = 1;

  /// The group-channel pane.
  static const int channel = 2;
}

/// The side column: classifier, plans and group chat in a fixed strip on
/// the RIGHT of the main conversation (owner layout directive). When at
/// least one column panel is open and the terminal is wide enough, the
/// conversation is narrowed by [panelWidthFor] columns and the column
/// owns that strip; panels stack top to bottom in [SideColumnRank]
/// order regardless of the order they were opened.
///
/// On terminals too narrow for both, the column is NOT applied and
/// panels fall back to today's behavior: stacked overlays over the
/// conversation's right edge — exactly [SidebarLayout]'s geometry,
/// delegated to one shared instance. Non-column panels (the tasks
/// overview) keep using [SidebarLayout] directly, unchanged.
final class SideColumnLayout {
  SideColumnLayout({
    required ScreenLayout Function() layout,
    required void Function(int width) setReservation,
  })  : _layout = layout,
        _setReservation = setReservation;

  /// Below this terminal width the column is not applied and panels
  /// fall back to the stacked layout. At [minimumScreenWidth] the
  /// column is 36 wide and the conversation keeps
  /// [minConversationWidth] — the two constants meet exactly there.
  static const int minimumScreenWidth = 96;

  /// The conversation must always keep at least this many columns.
  static const int minConversationWidth = 60;

  /// Narrowest usable column (chat lines wrap but stay readable).
  static const int minColumnWidth = 36;

  /// Widest the column grows on very wide terminals.
  static const int maxColumnWidth = 52;

  /// Shortest column entry that still shows content (bordered box).
  static const int panelMinimumHeight = 4;

  /// The channel pane's guaranteed minimum when the column overflows.
  static const int channelMinimumHeight = 8;

  /// The column width for a terminal [screenWidth] wide: roughly a
  /// third, clamped to a usable range.
  static int panelWidthFor(int screenWidth) =>
      (screenWidth ~/ 3).clamp(minColumnWidth, maxColumnWidth);

  /// Whether the column applies at this width.
  static bool fits(int screenWidth) =>
      screenWidth >= minimumScreenWidth &&
      screenWidth - panelWidthFor(screenWidth) >= minConversationWidth;

  final ScreenLayout Function() _layout;
  final void Function(int width) _setReservation;
  final _panels = <SideColumnPanel>[];
  int _serial = 0;
  bool _scheduled = false;
  SidebarLayout? _stacked;

  bool get isEmpty => _panels.isEmpty;

  /// Whether column mode is active: any open panel AND a wide-enough
  /// terminal. When false, panels render through the stacked fallback.
  bool get active =>
      _panels.any((p) => p._height > 0) && fits(_layout().width);

  /// Register a panel. [rank] fixes its position ([SideColumnRank]).
  SideColumnPanel register(void Function() repaint, {required int rank}) {
    final panel = SideColumnPanel._(this, repaint, rank, ++_serial);
    _panels.add(panel);
    _changed();
    return panel;
  }

  void _changed() {
    _applyReservation();
    if (_scheduled) return;
    _scheduled = true;
    scheduleMicrotask(() {
      _scheduled = false;
      for (final panel in _panels.toList()) {
        if (!panel._closed) panel._repaint();
      }
    });
  }

  /// Keep the screen reservation in step with the column's state. The
  /// reservation drives a screen relayout, which repaints the narrowed
  /// conversation and (through the microtask above) the column itself.
  void _applyReservation() {
    _setReservation(active ? panelWidthFor(_layout().width) : 0);
  }

  /// The stacked fallback, lazily built over the conversation's chat
  /// rect — which is the full-width chat exactly when the column is
  /// inactive, so the fallback viewport is today's viewport.
  SidebarLayout _fallback() => _stacked ??= SidebarLayout(() => _layout().chat);

  /// Column geometry for [target]: the strip partitioned in rank order.
  ///
  /// Each open panel gets its requested height, capped so every LATER
  /// panel still keeps its minimum; a panel that cannot hold its own
  /// minimum collapses (renders nowhere) and releases its rows to the
  /// panels after it. The channel pane (rank 2) asks for everything, so
  /// it takes the remainder — the majority of the column — and carries
  /// the largest minimum.
  Rect _columnBounds(SideColumnPanel target) {
    final area = _layout().rightColumn;
    if (area.isEmpty) return Rect.empty;
    final open = _panels.where((p) => p._height > 0).toList()
      ..sort((a, b) => a._rank == b._rank
          ? a._serial.compareTo(b._serial)
          : a._rank.compareTo(b._rank));
    var row = area.row;
    for (var i = 0; i < open.length; i++) {
      final panel = open[i];
      final minimum = panel._minimumHeight;
      var laterMinimums = 0;
      for (var j = i + 1; j < open.length; j++) {
        laterMinimums += open[j]._minimumHeight;
      }
      final available = area.bottom - row + 1;
      final grant = panel._height < available - laterMinimums
          ? panel._height
          : (available - laterMinimums).clamp(0, panel._height);
      if (grant < minimum) {
        if (identical(panel, target)) return Rect.empty;
        continue; // collapsed: its rows pass to the panels after it
      }
      if (identical(panel, target)) {
        return Rect(
            row: row, col: area.col, width: area.width, height: grant);
      }
      row += grant;
    }
    return Rect.empty;
  }

  Rect _bounds(SideColumnPanel target) {
    if (target._closed) return Rect.empty;
    if (active) return _columnBounds(target);
    return target._proxy?.bounds ?? Rect.empty;
  }
}

/// A panel's handle: request a size, read back where it landed.
final class SideColumnPanel {
  SideColumnPanel._(this._column, this._repaint, this._rank, this._serial);

  final SideColumnLayout _column;
  final void Function() _repaint;
  final int _rank;
  final int _serial;
  int _height = 0, _width = 44;
  bool _closed = false;
  bool _focused = false;
  SidebarPanel? _proxy;

  int get _minimumHeight => _rank == SideColumnRank.channel
      ? SideColumnLayout.channelMinimumHeight
      : SideColumnLayout.panelMinimumHeight;

  /// The panel's rank in the column (see [SideColumnRank]).
  int get rank => _rank;

  /// Whether column mode is active — panels use this to pick their
  /// column presentation vs their stacked-era one. The channel pane,
  /// for example, is a full-screen modal only while this is false.
  bool get columnActive => _column.active;

  /// Where this panel renders. Empty when closed, hidden, or collapsed
  /// by vertical overflow.
  Rect get bounds => _column._bounds(this);

  /// Request a height in rows (0 hides). In column mode every panel
  /// shares the column's width and fixed order, so only [height]
  /// matters there; [width] and [focused] drive the stacked fallback
  /// (same meaning as [SidebarPanel.requestSize]).
  void requestSize(
      {required int height, int width = 44, bool focused = false}) {
    if (_closed) return;
    final h = height == 0 ? 0 : height.clamp(4, 10000),
        w = width.clamp(8, 10000);
    // Keep the fallback proxy in step even in column mode, so a mode
    // flip (terminal resized across the threshold) finds it current.
    if (_proxy == null) {
      _proxy = _column._fallback().register(_repaint, priority: _stackPriority);
    }
    _proxy!.requestSize(height: h, width: w, focused: focused);
    if (_height == h && _width == w && _focused == focused) return;
    _height = h;
    _width = w;
    _focused = focused;
    _column._changed();
  }

  /// Stacked-fallback priority, matching the pre-column sidebar
  /// priorities so the fallback stack keeps today's order.
  int get _stackPriority => switch (_rank) {
        SideColumnRank.classifier => 20,
        SideColumnRank.plans => 10,
        _ => 30,
      };

  /// Releases the panel's slot (and the reservation, when last).
  void dispose() {
    if (_closed) return;
    _closed = true;
    _proxy?.dispose();
    _proxy = null;
    _column._panels.remove(this);
    _column._changed();
  }
}
