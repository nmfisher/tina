import 'package:tina_console/tina_console.dart';

/// Presentation values supplied by the workspace, without session/engine APIs.
final class PanelChoice {
  const PanelChoice(this.label, this.state, {required this.hidden});
  final String label, state;
  final bool hidden;
}

/// Focusable status-bar entry and its panel controls. Conversation execution
/// continues while this view owns selection keys; dialogs retain precedence.
final class PanelsStatus implements PanelInputTarget {
  PanelsStatus({
    required this.context,
    required this.choices,
    required this.restore,
    required this.minimize,
    required this.maximize,
    required this.onDismiss,
  });
  final ConsoleContext context;
  final List<PanelChoice> Function() choices;
  final void Function(int) restore, minimize, maximize;
  final void Function() onDismiss;
  OverlayRegion? _overlay;
  ScreenCursor? _cursor;
  bool _focused = false, _highlighted = false, _open = false;
  int _selected = 0, _offset = 0;
  Screen get screen => context.screen;

  List<RenderLine> status() {
    final panels = choices();
    final hidden = panels.where((p) => p.hidden).length;
    final count = '${panels.length} ${panels.length == 1 ? 'panel' : 'panels'}';
    return [
      RenderLine(runs: [
        RenderRun(
            '$count${hidden == 0 ? '' : ' ($hidden hidden)'}${_focused ? ' · Enter panels' : ''}',
            _highlighted
                ? screen.theme.border.selection
                : _focused
                    ? screen.theme.border.focus
                    : null)
      ])
    ];
  }

  @override
  Rect get bounds => Rect(
      row: screen.layout.stripRow,
      col: 0,
      width: screen.layout.width,
      height: 1);
  @override
  bool get hasFocus => _focused;
  @override
  bool get canFocus => choices().isNotEmpty;
  @override
  PanelInputMode get inputMode => PanelInputMode.commands;

  @override
  void focus() {
    _focused = true;
    _highlighted = false;
    _cursor ??= screen.claimCursor();
    context.refreshStatus();
  }

  @override
  void blur() {
    _focused = false;
    _highlighted = false;
    _open = false;
    _overlay?.hide();
    onDismiss();
    _cursor?.release();
    _cursor = null;
    context.refreshStatus();
  }

  @override
  void highlight() {
    _highlighted = true;
    context.refreshStatus();
  }

  @override
  void unhighlight() {
    _highlighted = false;
    context.refreshStatus();
  }

  @override
  bool handleEvent(InputEvent event) {
    if (!_focused) return false;
    final panels = choices();
    if (panels.isEmpty) return true;
    _selected = _selected.clamp(0, panels.length - 1);
    if (event is ControlKey && event.code == ControlCode.enter) {
      if (_open) {
        restore(_selected);
      } else {
        _open = true;
        _render();
      }
      return true;
    }
    if (_open && event is ArrowKey) {
      switch (event.direction) {
        case ArrowDirection.up:
          _selected = (_selected - 1) % panels.length;
        case ArrowDirection.down:
          _selected = (_selected + 1) % panels.length;
        default:
          return true;
      }
      _render();
      return true;
    }
    if (_open && event is CharInput) {
      switch (event.text.toLowerCase()) {
        case 'm':
          minimize(_selected);
        case 'x':
          maximize(_selected);
        default:
          return true;
      }
      refresh();
      return true;
    }
    // Selection keys never edit or submit the conversation draft.
    return event is CharInput ||
        event is PasteInput ||
        event is EditingKey ||
        event is ArrowKey ||
        (event is ControlKey &&
            (event.code == ControlCode.tab ||
                event.code == ControlCode.backspace));
  }

  void refresh() {
    context.refreshStatus();
    if (_open) _render();
  }

  void _render() {
    final panels = choices();
    if (panels.isEmpty) return;
    _selected = _selected.clamp(0, panels.length - 1);
    final layout = screen.layout;
    final width = (layout.width - 2).clamp(0, 76);
    final height =
        (panels.length + 5).clamp(0, layout.stripRow - layout.chat.row);
    final room = (height - 5).clamp(1, panels.length);
    if (_selected < _offset) _offset = _selected;
    if (_selected >= _offset + room) _offset = _selected - room + 1;
    _offset = _offset.clamp(0, (panels.length - room).clamp(0, panels.length));
    final body = [
      for (var i = _offset; i < panels.length && i < _offset + room; i++)
        '${i == _selected ? '❯' : ' '} ${panels[i].label} · ${panels[i].state}',
      'M minimize · X toggle maximize',
    ];
    final lines = dialogBoxLines(
        width: width,
        height: height,
        title: 'Panels',
        body: body,
        footer: '↑↓ select · Enter restore · Esc chat',
        paint: (s) => screen.colorize(screen.theme.border.focus, s));
    _overlay ??= OverlayRegion(screen, Rect.empty);
    _overlay!.update(
        bounds: Rect(
            row: layout.stripRow - height,
            col: (layout.width - width) ~/ 2,
            width: width,
            height: height),
        lines: lines);
  }

  void dispose() {
    blur();
    _overlay?.dispose();
    _overlay = null;
  }
}
