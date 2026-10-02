import 'dart:convert';
import 'package:classification/plugin.dart';
import 'package:tina_console/tina_console.dart';

/// One selectable stage, question, or choice in the actual execution history.
final class ClassificationPanelRow {
  const ClassificationPanelRow(this.exchange, this.label, this.depth,
      {this.question, this.choice});
  final ClassificationExchange exchange;
  final String label;
  final int depth;
  final String? question, choice;
  (int, String?, String?) get key => (exchange.id, question, choice);
}

Map<String, dynamic> _object(String text) {
  try {
    final value = jsonDecode(text);
    if (value is Map<String, dynamic>) return value;
  } catch (_) {}
  return {};
}

String _answer(Object? answer) {
  if (answer is! Map) return 'waiting';
  if (answer['noul'] case final num yes)
    return 'P(yes) ${(yes * 100).toStringAsFixed(1)}%';
  final probability = answer['confidence'] ?? answer['noul'];
  final confidence =
      probability is num ? ' ${(probability * 100).toStringAsFixed(1)}%' : '';
  return '${answer['choice'] ?? (answer['noul'] is num ? 'yes' : 'score ${answer['score']}')}$confidence';
}

/// All evaluated questions/options are included in hierarchy mode, including
/// negative answers. No hypothetical, unevaluated branches are invented.
List<ClassificationPanelRow> classificationPanelRows(ClassificationTrace trace,
    {required bool hierarchy}) {
  final rows = <ClassificationPanelRow>[];
  final depths = <int, int>{};
  for (final e in trace.exchanges) {
    final depth =
        hierarchy && e.parentId != null ? (depths[e.parentId] ?? -1) + 1 : 0;
    depths[e.id] = depth;
    final phase = switch (e.phase) {
      ClassificationExchangePhase.pending => 'waiting…',
      ClassificationExchangePhase.complete => 'done',
      ClassificationExchangePhase.failed => 'failed',
      ClassificationExchangePhase.cancelled => 'cancelled',
    };
    rows.add(ClassificationPanelRow(
        e,
        '#${e.id} ${e.title} · $phase${e.parentId == null && hierarchy ? ' · input ${e.inputId}' : ''}',
        depth));
    if (!hierarchy) continue;
    final request = _object(e.request), response = _object(e.response);
    final questions =
        e.questions.isNotEmpty ? e.questions : request['questions'];
    final answers = e.answers.isNotEmpty ? e.answers : response['answers'];
    if (questions is! Map) continue;
    for (final entry in questions.entries) {
      final id = '${entry.key}', answer = answers is Map ? answers[id] : null;
      rows.add(ClassificationPanelRow(
          e,
          '$id · ${answer == null && !e.pending ? phase : _answer(answer)}',
          depth + 1,
          question: id));
      final q = entry.value;
      if (q is! Map || q['type'] != 'choice' || q['criteria'] is! Map) continue;
      final probabilities = answer is Map ? answer['probabilities'] : null;
      for (final option in (q['criteria'] as Map).entries) {
        final value = option.value,
            p = probabilities is Map ? probabilities[option.key] : null;
        final label = value is Map ? value['label'] ?? option.key : option.key;
        final selected = answer is Map && answer['choice'] == option.key;
        rows.add(ClassificationPanelRow(
            e,
            '${selected ? '✓ ' : ''}$label${p is num ? ' · ${(p * 100).toStringAsFixed(1)}%' : ''}',
            depth + 2,
            question: id,
            choice: '${option.key}'));
      }
    }
  }
  return rows;
}

String _pretty(String text) {
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(text));
  } catch (_) {
    return text;
  }
}

String _safe(String text) =>
    text.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ' ');

/// Inspection never owns a model turn. It participates in the normal focus
/// ring, yields to dialogs, and retains its history across console reattachment.
final class ClassificationPanel implements PanelInputTarget {
  ClassificationPanel({required this.plugin, required this.context});
  final ClassificationPlugin plugin;
  final ConsoleContext context;
  Screen get screen => context.screen;
  FocusManager? focusManager;
  SidebarPanel? _slot;
  OverlayRegion? _region;
  ScreenCursor? _cursor;
  bool _started = false,
      _focused = false,
      _highlighted = false,
      _hidden = false;
  bool _explicit = false;
  bool _hierarchy = false, _details = false;
  int _selected = 0, _offset = 0, _room = 1, _maxOffset = 0, _revision = -1;
  List<ClassificationPanelRow> _rows = [];
  (int, int, (int, String?, String?))? _detailKey;
  List<String> _detailCache = [];
  (int, (int, String?, String?)?)? _previewKey;
  List<String> _previewCache = [];
  ClassificationPanelRow? get selected =>
      _rows.isEmpty ? null : _rows[_selected.clamp(0, _rows.length - 1)];
  bool get hierarchy => _hierarchy;
  bool get details => _details;
  bool get regionVisible => _region?.isVisible == true;
  @override
  bool get hasFocus => _focused;
  @override
  bool get canFocus => regionVisible && context.isActive;
  @override
  Rect get bounds => regionVisible ? _region!.bounds : Rect.empty;
  @override
  PanelInputMode get inputMode => PanelInputMode.commands;

  void start() {
    _started = true;
    focusManager = context.input.focusManager;
    _slot = context.bindSidebarPanel(refresh, priority: 20);
    focusManager?.register(this);
    refresh();
  }

  void toggle() {
    _hidden = !_hidden;
    refresh();
  }

  void show({bool? hierarchy}) {
    _hidden = false;
    _explicit = true;
    if (hierarchy != null && hierarchy != _hierarchy) {
      _hierarchy = hierarchy;
      _revision = -1;
    }
    if (focusManager == null)
      refresh();
    else
      focusManager!.focusPanel(this);
  }

  @override
  void focus() {
    _focused = true;
    _highlighted = false;
    _cursor ??= screen.claimCursor();
    _offset = _selected;
    refresh();
  }

  @override
  void blur() {
    _focused = false;
    _cursor?.release();
    _cursor = null;
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
        _move(-1);
      case ArrowKey(direction: ArrowDirection.down):
        _move(1);
      case ArrowKey(direction: ArrowDirection.pageUp):
        _scroll(-_room);
      case ArrowKey(direction: ArrowDirection.pageDown):
        _scroll(_room);
      case ScrollEvent(:final up):
        _scroll(up ? -1 : 1);
      case ArrowKey(direction: ArrowDirection.right):
      case ControlKey(code: ControlCode.enter):
        _details = selected != null;
        _offset = 0;
        refresh();
      case ArrowKey(direction: ArrowDirection.left):
        _details = false;
        _offset = _selected;
        refresh();
      case CharInput(text: 'h'):
        _hierarchy = !_hierarchy;
        _details = false;
        _revision = -1;
        _offset = 0;
        refresh();
      case EscapeKey():
        if (!_details) return false;
        _details = false;
        _offset = _selected;
        refresh();
      case ControlKey(code: ControlCode.ctrlC || ControlCode.ctrlD):
        return false;
      default:
        break;
    }
    return true;
  }

  void _move(int amount) {
    if (_details) {
      _scroll(amount);
      return;
    }
    _selected =
        (_selected + amount).clamp(0, _rows.isEmpty ? 0 : _rows.length - 1);
    if (_selected < _offset) _offset = _selected;
    if (_selected >= _offset + _room) _offset = _selected - _room + 1;
    refresh();
  }

  void _scroll(int amount) {
    _offset = (_offset + amount).clamp(0, _maxOffset);
    refresh();
  }

  List<String> _detailLines(int width) {
    final row = selected;
    if (row == null) return [];
    final key = (plugin.trace.revision, width, row.key);
    if (_detailKey == key) return _detailCache;
    _detailKey = key;
    final e = row.exchange;
    String request = e.request, response = e.response;
    if (row.question != null) {
      final questions = e.questions.isNotEmpty
              ? e.questions
              : _object(request)['questions'],
          answers =
              e.answers.isNotEmpty ? e.answers : _object(response)['answers'];
      final q = questions is Map ? questions[row.question] : null;
      final a = answers is Map ? answers[row.question] : null;
      final criteria = q is Map ? q['criteria'] : null;
      final definition = row.choice == null
          ? q
          : criteria is Map
              ? criteria[row.choice]
              : null;
      request = const JsonEncoder.withIndent('  ').convert({
        'state': _object(e.request)['state'],
        'question': row.question,
        'definition': definition
      });
      response = const JsonEncoder.withIndent('  ').convert(a);
    }
    return _detailCache = [
      'Input: ${_safe(e.inputId)}',
      'Request',
      for (final line in _pretty(request).split('\n'))
        ...wrapDialogText(line, width),
      '',
      'Response${e.pending ? ' · waiting…' : ''}',
      for (final line in _pretty(response).split('\n'))
        ...wrapDialogText(line, width),
      if (e.error != null) ...wrapDialogText('Error: ${e.error}', width),
    ];
  }

  List<String> _preview() {
    final e = selected?.exchange;
    if (e == null) return [plugin.status.label];
    final key = (plugin.trace.revision, selected?.key);
    if (_previewKey == key) return _previewCache;
    _previewKey = key;
    final request = _object(e.request), response = _object(e.response);
    final state = request['state'],
        questions = request['questions'],
        answers = response['answers'];
    final evidence = state is Map ? state['evidence'] : null;
    final latest =
        evidence is List && evidence.isNotEmpty ? evidence.last : null;
    final text = latest is Map ? latest['text'] : null;
    return _previewCache = [
      selected!.label,
      if (text != null) 'Input: $text',
      'Sent: ${questions is Map ? questions.keys.join(', ') : 'fresh-context category request'}',
      if (answers is Map)
        'Reply: ${answers.entries.where((a) {
              final value = a.value;
              if (value is! Map) return false;
              final p = value['noul'];
              return value['type'] != 'noul' || (p is num && p >= .5);
            }).map((a) => '${a.key}: ${_answer(a.value)}').join(', ')}'
      else
        'Reply: ${e.response.isEmpty ? (e.error ?? 'waiting…') : e.response}',
    ];
  }

  void refresh() {
    if (!_started || context.isReadingKey) return;
    if (_hidden ||
        !context.isActive ||
        (!_explicit && plugin.trace.exchanges.isEmpty)) {
      _slot?.requestSize(height: 0);
      _hide();
      return;
    }
    if (_revision != plugin.trace.revision) {
      final key = selected?.key;
      _rows = classificationPanelRows(plugin.trace, hierarchy: _hierarchy);
      final preserved = _rows.indexWhere((r) => r.key == key);
      _selected = _focused && preserved >= 0
          ? preserved
          : (_rows.length - 1).clamp(0, _rows.length);
      _revision = plugin.trace.revision;
    }
    if (!_focused && _rows.isNotEmpty)
      _selected = _rows.lastIndexWhere((r) => r.question == null);
    final chat = context.chat.bounds;
    _slot?.requestSize(
        height: _focused
            ? chat.height
            : _hierarchy
                ? 14
                : 8,
        width: _focused ? 84 : 44,
        focused: _focused);
    final area = _slot!.bounds;
    if (area.isEmpty) {
      _hide();
      return;
    }
    final width = area.width - 4;
    _room = (area.height - 3).clamp(1, area.height);
    final preview = _focused || _hierarchy ? const <String>[] : _preview();
    final content = _details && _focused
        ? _detailLines(width)
        : _focused || _hierarchy
            ? _rows.isEmpty
                ? [plugin.status.label]
                : [
                    for (final (i, row) in _rows.indexed)
                      '${i == _selected ? '› ' : '  '}${'  ' * row.depth.clamp(0, 4)}${row.label}'
                  ]
            : _room >= 5
                ? [plugin.status.label, ...preview]
                : _room == 4
                    ? [plugin.status.label, ...preview.skip(1)]
                    : [
                        plugin.status.label,
                        ...preview.where((s) =>
                            s.startsWith('Sent:') || s.startsWith('Reply:'))
                      ];
    _maxOffset = (content.length - _room).clamp(0, content.length);
    _offset = _focused
        ? _offset.clamp(0, _maxOffset)
        : _hierarchy
            ? _maxOffset
            : 0;
    final footer = _focused
        ? (_details
            ? '↑↓ scroll · ← back · h hierarchy'
            : '↑↓ select · → details · h hierarchy')
        : 'Ctrl+G, Tab, Enter focus · F6 hide';
    String paint(String text) => screen.colorize(
        _focused
            ? screen.theme.chat.cyan
            : _highlighted
                ? screen.theme.chat.yellow
                : screen.theme.chat.dim,
        text);
    String body(String text) {
      final fit = clipDialogText(_safe(text), width);
      return '${paint('│')} $fit${' ' * (width - visibleWidth(fit))} ${paint('│')}';
    }

    final title = clipDialogText(
        ' classification${_hierarchy ? ' · hierarchy' : ''} ', area.width - 2);
    final lines = [
      paint('┌$title${'─' * (area.width - 2 - visibleWidth(title))}┐'),
      for (final line in content.skip(_offset).take(_room)) body(line),
      for (var i = content.skip(_offset).take(_room).length; i < _room; i++)
        body(''),
      body(footer),
      paint('└${'─' * (area.width - 2)}┘'),
    ];
    final region = _region ??= OverlayRegion(screen, area);
    if (region.isVisible &&
        (region.bounds.row != area.row ||
            region.bounds.col != area.col ||
            region.bounds.width != area.width ||
            region.bounds.height != area.height)) {
      region.hide();
      context.chat.repaint();
    }
    region.update(bounds: area, lines: lines);
  }

  void _hide() {
    _cursor?.release();
    _cursor = null;
    final wasFocused = _focused, wasHighlighted = _highlighted;
    _focused = false;
    _highlighted = false;
    if (wasFocused && identical(focusManager?.focused, this))
      focusManager?.returnHome();
    if (wasHighlighted && identical(focusManager?.highlighted, this))
      focusManager?.cancel();
    if (regionVisible) {
      _region!.hide();
      context.chat.repaint();
    }
  }

  void dispose() {
    _started = false;
    _hide();
    focusManager?.unregister(this);
    _slot?.dispose();
    _slot = null;
    _region?.dispose();
    _region = null;
  }
}
