import 'package:tina_console/tina_console.dart';
import 'package:tina_console/src/term_width.dart';

typedef ConversationSidebarEntry = ({String id, String label, int depth});

/// The conversation tree stays focused while arrows select the active view.
/// Enter transfers keyboard focus to that view; the active row stays marked
/// when focus returns to the conversation.
class ConversationSidebar implements Focusable {
  ConversationSidebar(this.screen)
    : _overlay = OverlayRegion(screen, Rect.empty);

  final Screen screen;
  final OverlayRegion _overlay;
  List<ConversationSidebarEntry> _entries = const [];
  String? _activeId;
  int _offset = 0;
  bool _focused = false;
  bool _highlighted = false;

  void Function(String id)? onSelect;
  void Function(String id)? onEnter;

  String? get activeId => _activeId;
  List<ConversationSidebarEntry> get entries => List.unmodifiable(_entries);

  @override
  Rect get bounds => screen.layout.sidebar;
  @override
  bool get hasFocus => _focused;
  @override
  bool get canFocus => !bounds.isEmpty && _entries.isNotEmpty;

  void update(
    List<ConversationSidebarEntry> entries, {
    required String activeId,
  }) {
    _entries = List.unmodifiable(entries);
    _activeId = activeId;
    render();
  }

  @override
  void focus() {
    _focused = true;
    _highlighted = false;
    render();
  }

  @override
  void blur() {
    _focused = false;
    render();
  }

  @override
  void highlight() {
    _highlighted = true;
    render();
  }

  @override
  void unhighlight() {
    _highlighted = false;
    render();
  }

  void _move(int delta) {
    if (_entries.isEmpty) return;
    final current = _entries.indexWhere((e) => e.id == _activeId);
    final next = ((current < 0 ? 0 : current) + delta).clamp(
      0,
      _entries.length - 1,
    );
    final id = _entries[next].id;
    if (id == _activeId) return;
    screen.frame(() {
      _activeId = id;
      onSelect?.call(id);
      render();
    });
  }

  @override
  bool handleEvent(InputEvent event) {
    if (event is ArrowKey) {
      switch (event.direction) {
        case ArrowDirection.up:
          _move(-1);
        case ArrowDirection.down:
          _move(1);
        case ArrowDirection.pageUp:
          _move(-(bounds.height - 3).clamp(1, 10000));
        case ArrowDirection.pageDown:
          _move((bounds.height - 3).clamp(1, 10000));
        case ArrowDirection.right:
          if (_activeId != null) onEnter?.call(_activeId!);
        case ArrowDirection.left:
          break;
      }
      return true;
    }
    if (event is ScrollEvent) {
      _move(event.up ? -1 : 1);
      return true;
    }
    if (event is ControlKey) {
      if (event.code == ControlCode.ctrlC || event.code == ControlCode.ctrlD) {
        return false;
      }
      if (event.code == ControlCode.enter && _activeId != null) {
        onEnter?.call(_activeId!);
      }
      return true;
    }
    // Text and paste must not leak into the conversation editor.
    return event is! EscapeKey;
  }

  void render() {
    final b = bounds;
    if (b.isEmpty || b.width < 3 || b.height < 3) {
      _overlay.hide();
      return;
    }
    final width = b.width - 2;
    final count = b.height - 3;
    final active = _entries.indexWhere((e) => e.id == _activeId);
    if (active >= 0) {
      if (active < _offset) _offset = active;
      if (active >= _offset + count) _offset = active - count + 1;
    }
    _offset = _offset.clamp(0, (_entries.length - count).clamp(0, 1 << 30));
    final accent = _highlighted
        ? screen.theme.border.selection
        : _focused
        ? screen.theme.border.focus
        : screen.theme.chat.dim;
    String border(String s) => screen.colorize(accent, s);
    final lines = <String>[
      border('┌${_fit(' conversations ', width, fill: '─')}┐'),
    ];
    for (var row = 0; row < count; row++) {
      final index = _offset + row;
      var text = ' ' * width;
      if (index < _entries.length) {
        final entry = _entries[index];
        final selected = entry.id == _activeId;
        final indent =
            ' ' * (entry.depth * 2).clamp(0, (width - 5).clamp(0, width));
        text = _fit('${selected ? '▸' : ' '} $indent${entry.label}', width);
        if (selected)
          text = screen.colorize(screen.theme.completion.selected, text);
      }
      lines.add('${border('│')}$text${border('│')}');
    }
    final above = _offset > 0 ? '↑$_offset ' : '';
    final below = _entries.length - _offset - count;
    final footer = '$above${below > 0 ? '↓$below ' : ''}↑↓ select';
    lines.add('${border('│')}${_fit(footer, width)}${border('│')}');
    lines.add(border('└${'─' * width}┘'));
    _overlay.update(bounds: b, lines: lines);
  }

  static String _fit(String text, int width, {String fill = ' '}) {
    final out = StringBuffer();
    var used = 0;
    for (final rune in text.runes) {
      final size = runeWidth(rune);
      if (used + size > width) break;
      out.writeCharCode(rune);
      used += size;
    }
    return '$out${fill * (width - used)}';
  }

  void dispose() => _overlay.dispose();
}
