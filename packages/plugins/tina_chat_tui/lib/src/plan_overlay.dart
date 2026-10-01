import 'dart:async';
import 'package:tina_console/tina_console.dart';
import 'package:tina_plans/tina_plans.dart';

enum PlanOverlayMode { auto, manual, off }

typedef Plan = PlanState;
typedef PlanItem = PlanEntryItem;
typedef PlanPaint = String Function(String text, String? code);
typedef _Address = (int, int?);

extension on PlanState {
  Iterable<PlanEntryItem> get allItems => [
        for (final item in items) ...[item, ...item.children]
      ];
}

class PlanOverlayUi {
  const PlanOverlayUi({
    this.collapsed = false,
    this.collapsedRoots = const {},
    this.expandedItems = const {},
    this.selectedIndex,
    this.highlighted = false,
    this.focused = false,
    this.offset = 0,
    this.maxRows,
  });
  final bool collapsed;
  final Set<int> collapsedRoots;
  final Set<(int, int?)> expandedItems;
  final int? selectedIndex;
  final bool highlighted, focused;
  final int offset;
  final int? maxRows;
}

class _Row {
  const _Row(this.item, this.rootIndex, this.childIndex);
  final PlanItem item;
  final int rootIndex;
  final int? childIndex;
  int get depth => childIndex == null ? 0 : 1;
  _Address get address => (rootIndex, childIndex);
}

List<_Row> _visibleRows(Plan plan, {Set<int> collapsedRoots = const {}}) => [
      for (final (ri, item) in plan.items.indexed) ...[
        _Row(item, ri, null),
        if (!collapsedRoots.contains(ri))
          for (final (ci, child) in item.children.indexed) _Row(child, ri, ci),
      ],
    ];

List<(String, String?)> _body(Plan plan, PlanOverlayUi ui, int innerWidth) {
  if (ui.collapsed) {
    final active = plan.allItems.where((i) => i.state == 'in_progress');
    return [for (final item in active) ('● ${item.text}', 'accent')];
  }
  final rows = _visibleRows(plan, collapsedRoots: ui.collapsedRoots);
  return [
    for (final (i, row) in rows.indexed)
      ..._itemLines(row, ui, innerWidth, selected: i == ui.selectedIndex),
  ];
}

List<(String, String?)> _itemLines(_Row row, PlanOverlayUi ui, int width,
    {required bool selected}) {
  final expanded = ui.expandedItems.contains(row.address);
  final indent = '  ' * row.depth;
  final state = switch (row.item.state) {
    'done' => '✓',
    'in_progress' => '●',
    _ => '·',
  };
  // Selection and disclosure share one column; progress uses a dot, not
  // another arrow. The selected row must remain identifiable without color.
  final marker = selected
      ? '❯'
      : expanded
          ? '▾'
          : '▸';
  final prefix = '$indent$marker $state ';
  final kind = selected
      ? 'accent'
      : row.item.state == 'done'
          ? 'ok'
          : null;
  final text = _safe(row.item.text);
  if (!expanded) {
    final count = row.childIndex == null &&
            row.item.children.isNotEmpty &&
            ui.collapsedRoots.contains(row.rootIndex)
        ? ' (+${row.item.children.length})'
        : '';
    final titleWidth =
        (width - visibleWidth(prefix) - visibleWidth(count)).clamp(0, width);
    return [('$prefix${_fit(text, titleWidth)}$count', kind)];
  }
  final lines =
      wrapDialogWords(text, (width - visibleWidth(prefix)).clamp(1, width));
  final summaryIndent = ' ' * visibleWidth(prefix).clamp(0, width - 1);
  final summaryWidth = width - summaryIndent.length;
  return [
    for (final (i, line) in lines.indexed)
      ('${i == 0 ? prefix : ' ' * visibleWidth(prefix)}$line', kind),
    if (row.item.summary.trim().isNotEmpty)
      for (final paragraph in row.item.summary.split('\n'))
        for (final line in wrapDialogWords(_safe(paragraph), summaryWidth))
          ('$summaryIndent$line', null),
  ];
}

/// Pure rendering. Expanded text wraps; viewport clipping never wraps chrome.
List<String> renderPlanOverlayLines({
  required Plan plan,
  required PlanOverlayUi ui,
  required int width,
  required PlanPaint paint,
}) {
  if (width < 8) return const [];
  final inner = width - 4;
  final all = plan.allItems.toList();
  final done = all.where((i) => i.state == 'done').length;
  final title = _fit(' plan · $done/${all.length} ', width - 2);
  final border = ui.highlighted
      ? 'highlight'
      : ui.focused
          ? 'accent'
          : 'dim';
  final body = _body(plan, ui, inner);
  final offset = ui.offset.clamp(0, body.isEmpty ? 0 : body.length - 1);
  final visible = body.skip(offset).take(ui.maxRows ?? body.length).toList();
  final hasMore = offset > 0 || offset + visible.length < body.length;
  final footer = ui.focused
      ? '↑↓ select · ←→ fold · Esc chat'
      : 'Ctrl+G, Tab, Enter focus · Ctrl+P hide';
  String box(String text, [String? kind]) {
    final shown = _fit(text, inner);
    return '${paint('│', border)} ${paint(shown, kind)}'
        '${' ' * (inner - visibleWidth(shown))} ${paint('│', border)}';
  }

  return [
    '${paint('┌', border)}$title${paint('─' * (width - 2 - visibleWidth(title)), border)}${paint('┐', border)}',
    for (final row in visible) box(row.$1, row.$2),
    box(
        hasMore
            ? '${offset + 1}–${offset + visible.length}/${body.length} · PgUp/PgDn scroll'
            : footer,
        'dim'),
    '${paint('└${'─' * (width - 2)}┘', border)}',
  ];
}

String _safe(String text) =>
    text.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ');
String _fit(String text, int width) => clipDialogText(_safe(text), width);

int planOverlayContentHeight(Plan plan,
        {required bool collapsed, Set<int> collapsedRoots = const {}}) =>
    (collapsed
        ? plan.allItems.where((i) => i.state == 'in_progress').length
        : _visibleRows(plan, collapsedRoots: collapsedRoots).length) +
    1;

/// A session-owned plan browser. Selection and expansion change only view
/// state; the panel never changes approval or item progress.
class PlanOverlay implements PanelInputTarget {
  PlanOverlay({
    required this.screen,
    required this.store,
    required this.context,
    this.focusManager,
    this.mode = PlanOverlayMode.auto,
  });
  final Screen screen;
  final PlanStore store;
  final ConsoleContext context;
  final FocusManager? focusManager;
  final PlanOverlayMode mode;
  OverlayRegion? _region;
  StreamSubscription<void>? _sub;
  bool _started = false, _focused = false, _highlighted = false;
  bool? _userOverride;
  int? _selected;
  int _offset = 0, _room = 1, _maxOffset = 0;
  bool _followSelection = true;
  final Set<_Address> _expanded = {};
  List<PlanItem> _previous = const [];

  bool get regionVisible => _region?.isVisible ?? false;
  bool get debugFocused => _focused;
  @override
  bool get hasFocus => _focused;
  @override
  bool get canFocus => regionVisible && context.isActive;
  @override
  Rect get bounds => regionVisible ? _region!.bounds : Rect.empty;
  @override
  PanelInputMode get inputMode => PanelInputMode.commands;
  Set<int> get _collapsedRoots => {
        for (final (i, _) in store.state.items.indexed)
          if (!_expanded.contains((i, null))) i
      };
  List<_Row> get _rows =>
      _visibleRows(store.state, collapsedRoots: _collapsedRoots);
  _Row? get _selectedRow {
    final rows = _rows, index = _selected;
    return index == null || index < 0 || index >= rows.length
        ? null
        : rows[index];
  }

  PlanItem? get selectedItem => _selectedRow?.item;
  int get firstActionableIndex {
    final i = _rows.indexWhere((r) => r.item.state != 'done');
    return i < 0 ? 0 : i;
  }

  @override
  void focus() {
    _focused = true;
    _highlighted = false;
    _selected ??= firstActionableIndex;
    _followSelection = true;
    refresh();
  }

  @override
  void blur() {
    _focused = false;
    refresh();
  }

  @override
  void highlight() {
    _highlighted = true;
    refresh();
  }

  @override
  void unhighlight() {
    _highlighted = false;
    refresh();
  }

  @override
  bool handleEvent(InputEvent event) {
    if (!_focused || !canFocus) return false;
    switch (event) {
      case ArrowKey(direction: ArrowDirection.up):
        _select((_selected ?? 0) - 1);
      case ArrowKey(direction: ArrowDirection.down):
        _select((_selected ?? -1) + 1);
      case ArrowKey(direction: ArrowDirection.right):
        _expandSelection(true);
      case ArrowKey(direction: ArrowDirection.left):
        _expandSelection(false);
      case ArrowKey(direction: ArrowDirection.pageUp):
        _scroll(-_room);
      case ArrowKey(direction: ArrowDirection.pageDown):
        _scroll(_room);
      case ScrollEvent(:final up):
        _scroll(up ? -3 : 3);
      case ControlKey(code: ControlCode.enter):
      case CharInput(text: ' '):
        _expandSelection();
      case EscapeKey():
        return false; // the generic focus ring returns to chat
      case ControlKey(code: ControlCode.ctrlC || ControlCode.ctrlD):
        return false;
      default:
        break; // a read-only panel never edits the conversation draft
    }
    return true;
  }

  void _expandSelection([bool? expanded]) {
    final row = _selectedRow;
    if (row == null) return;
    if (expanded ?? !_expanded.contains(row.address)) {
      _expanded.add(row.address);
    } else {
      _expanded.remove(row.address);
    }
    _followSelection = true;
    refresh();
  }

  void _select(int index) {
    final rows = _rows;
    if (rows.isEmpty) return;
    _selected = index.clamp(0, rows.length - 1);
    _followSelection = true;
    refresh();
  }

  void _scroll(int amount) {
    _offset = (_offset + amount).clamp(0, _maxOffset);
    _followSelection = false;
    refresh();
  }

  /// Preserve item identity across progress ticks/reordering; remove view
  /// state when its item disappears or its text changes.
  void _syncItems() {
    final current = store.state.items;
    if (identical(current, _previous)) return;
    final oldRows = _visibleRows(PlanState(items: _previous), collapsedRoots: {
      for (var i = 0; i < _previous.length; i++)
        if (!_expanded.contains((i, null))) i
    });
    (String, String?) identity(_Row row, List<PlanItem> items) => (
          items[row.rootIndex].text,
          row.childIndex == null ? null : row.item.text
        );
    final selected = _selected != null && _selected! < oldRows.length
        ? identity(oldRows[_selected!], _previous)
        : null;
    final expanded = {
      for (final row in _visibleRows(PlanState(items: _previous)))
        if (_expanded.contains(row.address)) identity(row, _previous)
    };
    _expanded.clear();
    for (final row in _visibleRows(store.state)) {
      if (expanded.contains(identity(row, current))) _expanded.add(row.address);
    }
    _previous = current;
    final rows = _rows;
    final preserved =
        rows.indexWhere((row) => identity(row, current) == selected);
    if (_selected != null)
      _selected = preserved >= 0
          ? preserved
          : _selected!.clamp(0, rows.isEmpty ? 0 : rows.length - 1);
  }

  void start() {
    if (_started) return;
    _started = true;
    focusManager?.register(this);
    _sub = store.changes.listen((_) => refresh());
    refresh();
  }

  void toggle() {
    _userOverride = !(_userOverride ?? mode == PlanOverlayMode.auto);
    refresh();
  }

  void relayout() => refresh();
  void render() => refresh();
  void refresh() {
    if (!_started || context.isReadingKey) return;
    final plan = store.state;
    final chat = context.chat.bounds;
    if (plan.isEmpty ||
        !context.isActive ||
        !(_userOverride ?? mode == PlanOverlayMode.auto) ||
        chat.width < 8 ||
        chat.height < 4) {
      _hide();
      return;
    }
    _syncItems();
    final width = chat.width.clamp(8, 44);
    // Even the smallest focusable viewport keeps one item and its controls.
    const chrome = 3;
    final collapsed = !_focused && _rows.length + chrome > chat.height;
    final ui = PlanOverlayUi(
      collapsed: collapsed,
      collapsedRoots: _collapsedRoots,
      expandedItems: _expanded,
      selectedIndex: _focused ? _selected : null,
      highlighted: _highlighted,
      focused: _focused,
    );
    final body = _body(plan, ui, width - 4);
    _room = (chat.height - chrome).clamp(1, body.isEmpty ? 1 : body.length);
    _maxOffset = (body.length - _room).clamp(0, body.length);
    _offset = _offset.clamp(0, _maxOffset);
    if (_focused && _followSelection && _selected != null) {
      var line = 0;
      for (final (i, row) in _rows.indexed) {
        if (i == _selected) break;
        line += _itemLines(row, ui, width - 4, selected: false).length;
      }
      if (line < _offset || line >= _offset + _room)
        _offset = line.clamp(0, _maxOffset);
    }
    final lines = renderPlanOverlayLines(
        plan: plan,
        ui: PlanOverlayUi(
            collapsed: collapsed,
            collapsedRoots: _collapsedRoots,
            expandedItems: _expanded,
            selectedIndex: _focused ? _selected : null,
            highlighted: _highlighted,
            focused: _focused,
            offset: _offset,
            maxRows: _room),
        width: width,
        paint: _themePaint);
    final bounds = Rect(
        row: chat.row,
        col: chat.col + chat.width - width,
        width: width,
        height: lines.length);
    final region = _region ??= OverlayRegion(screen, bounds);
    if (region.isVisible &&
        (region.bounds.row != bounds.row ||
            region.bounds.col != bounds.col ||
            region.bounds.width != bounds.width ||
            region.bounds.height != bounds.height)) {
      region.hide();
      context.chat.repaint();
    }
    region.update(bounds: bounds, lines: lines);
  }

  String _themePaint(String text, String? kind) {
    final style = switch (kind) {
      'dim' => screen.theme.chat.dim,
      'accent' => screen.theme.chat.cyan,
      'ok' => screen.theme.chat.green,
      'highlight' => screen.theme.chat.yellow,
      _ => null,
    };
    return style == null ? text : screen.colorize(style, text);
  }

  void _hide() {
    final wasFocused = _focused;
    final wasHighlighted = _highlighted;
    _focused = false;
    _highlighted = false;
    if (wasHighlighted && identical(focusManager?.highlighted, this)) {
      focusManager?.cancel();
    }
    if (wasFocused && identical(focusManager?.focused, this))
      focusManager?.returnHome();
    if (_region?.isVisible == true) {
      _region!.hide();
      context.chat.repaint();
    }
  }

  void dispose() {
    _started = false;
    if (identical(focusManager?.focused, this)) focusManager?.returnHome();
    focusManager?.unregister(this);
    unawaited(_sub?.cancel());
    _region?.dispose();
    _region = null;
  }
}
