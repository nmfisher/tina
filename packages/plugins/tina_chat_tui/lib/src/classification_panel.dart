import 'dart:convert';
import 'package:classification/plugin.dart';
import 'package:tina_console/tina_console.dart';

/// One selectable stage, question, or choice in the actual execution history.
enum ClassificationRowKind { classifier, question, choice }

final class ClassificationPanelRow {
  const ClassificationPanelRow(this.exchange, this.label, this.depth,
      {this.question,
      this.choice,
      this.kind = ClassificationRowKind.classifier});
  final ClassificationExchange exchange;
  final String label;
  final int depth;
  final String? question, choice;
  final ClassificationRowKind kind;
  (int, String?, String?, ClassificationRowKind) get key =>
      (exchange.id, question, choice, kind);
}

Map<String, dynamic> _object(String text) {
  try {
    final value = jsonDecode(text);
    if (value is Map<String, dynamic>) return value;
  } catch (_) {}
  return {};
}

String _name(String id, [Object? definition]) {
  if (definition is Map &&
      definition['label'] is String &&
      definition['label'] != 'instruction' &&
      definition['label'] != 'project question')
    return definition['label'] as String;
  const names = {
    'intent': 'Request type',
    'agentInstruction': 'Request to do work',
    'projectQuestion': 'Project question',
    'other': 'Other',
    'none': 'No Git action',
    'unknown': 'Unclear Git intent',
    'status': 'Check status',
    'diff': 'View changes',
    'log': 'View history',
    'show': 'Inspect a commit',
    'add': 'Stage changes',
    'commit': 'Commit changes',
    'push': 'Push changes',
    'pull': 'Pull changes',
    'fetch': 'Fetch updates',
    'branch': 'Manage branches',
    'switch': 'Switch branches',
    'checkout': 'Check out files or a branch',
    'merge': 'Merge branches',
    'rebase': 'Rebase commits',
    'stash': 'Stash changes',
    'reset': 'Reset changes',
    'restore': 'Restore files',
    'clone': 'Clone a repository',
    'init': 'Create a repository',
    'tag': 'Manage tags',
  };
  if (names[id] case final String name) return name;
  if (definition is Map && definition['label'] is String)
    return definition['label'] as String;
  return id
      .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
      .replaceAll(RegExp(r'[_-]'), ' ');
}

String _percent(num value) => '${(value * 100).toStringAsFixed(1)}% match';

String _score(num value) {
  final filled = (value * 4).round().clamp(0, 4);
  return '[${'#' * filled}${'-' * (4 - filled)}] ${_percent(value)}';
}

String _answer(Object? answer, [Object? question]) {
  if (answer is! Map) return 'Waiting for result';
  if (answer['noul'] case final num yes) return _percent(yes);
  final probability = answer['confidence'] ?? answer['noul'];
  final confidence = probability is num ? ' · ${_percent(probability)}' : '';
  final choice = answer['choice'];
  final criteria = question is Map ? question['criteria'] : null;
  return '${choice != null ? _name('$choice', criteria is Map ? criteria[choice] : null) : 'Score: ${answer['score']}'}$confidence';
}

Object? _choiceDefinition(Object? question, Object? choice) {
  final criteria = question is Map ? question['criteria'] : null;
  return criteria is Map ? criteria[choice] : null;
}

Map _questions(ClassificationExchange e) => e.questions.isNotEmpty
    ? e.questions
    : _object(e.request)['questions'] is Map
        ? _object(e.request)['questions'] as Map
        : const {};

Map _answers(ClassificationExchange e) => e.answers.isNotEmpty
    ? e.answers
    : _object(e.response)['answers'] is Map
        ? _object(e.response)['answers'] as Map
        : const {};

String _stage(ClassificationExchange e) => switch (e.classifierName) {
      'Intent' => 'Request type',
      'Git operations' => 'Git actions',
      _ => e.title.startsWith('Learn category')
          ? 'Learn a new request type'
          : e.classifierName,
    };

String _phase(ClassificationExchange e) => switch (e.phase) {
      ClassificationExchangePhase.pending => '◌ Running',
      ClassificationExchangePhase.complete => '✓ Complete',
      ClassificationExchangePhase.failed => '! Failed',
      ClassificationExchangePhase.cancelled => '– Cancelled',
    };

List _evidence(ClassificationExchange e) {
  final state = _object(e.request)['state'];
  return state is Map && state['evidence'] is List
      ? state['evidence'] as List
      : const [];
}

String? _input(ClassificationExchange e) {
  if (e.inputText != null) return e.inputText;
  final evidence = _evidence(e);
  final latest = evidence.isNotEmpty ? evidence.last : null;
  final text = latest is Map ? latest['text'] : _object(e.request)['input'];
  return text is String ? text : null;
}

String _result(ClassificationExchange e) {
  if (e.outcome case final ClassificationOutcome result)
    return '${result.unclear ? '? ' : ''}${result.label}';
  if (e.pending) return '[loading]';
  if (e.phase == ClassificationExchangePhase.cancelled) return '[cancelled]';
  if (e.error != null) return '! Failed: ${e.error}';
  final choices = _answers(e)
      .entries
      .where((a) => a.value is Map && (a.value as Map)['choice'] != null);
  if (choices.length == 1) {
    final answer = choices.single;
    return '? ${_answer(answer.value, _questions(e)[answer.key]).split(' · ').first}';
  }
  if (choices.isNotEmpty)
    return '? ${choices.map((a) => '${_name('${a.key}', _questions(e)[a.key])}: ${_answer(a.value, _questions(e)[a.key]).split(' · ').first}').join('; ')}';
  final response = _object(e.response);
  if (response['category'] case final Map category)
    return 'New category · ${category['label'] ?? category['id']}';
  if (response['existing_category'] case final String category)
    return 'Existing category · ${_name(category)}';
  return '${_answers(e).isEmpty ? 'No decoded result recorded' : 'Checks complete; inspect scores'}';
}

/// All evaluated questions/options are included in hierarchy mode, including
/// negative answers. No hypothetical, unevaluated branches are invented.
List<ClassificationPanelRow> classificationPanelRows(ClassificationTrace trace,
    {required bool hierarchy, Set<int> expanded = const {}, String? inputId}) {
  final rows = <ClassificationPanelRow>[];
  final exchanges = trace.exchanges
      .where((e) => inputId == null || e.inputId == inputId)
      .toList();
  final byId = {for (final e in exchanges) e.id: e};
  final visited = <int>{};
  void visit(ClassificationExchange e, int depth) {
    if (!visited.add(e.id)) return;
    final open = hierarchy || expanded.contains(e.id);
    final phase = _phase(e);
    rows.add(ClassificationPanelRow(
        e, '${open ? '▾' : '▸'} ${_stage(e)}: ${_result(e)}', depth));
    if (open) {
      final questions = _questions(e), answers = _answers(e);
      for (final entry in questions.entries) {
        final id = '${entry.key}', answer = answers[id];
        rows.add(ClassificationPanelRow(
            e,
            '${_name(id, entry.value)} · ${answer is Map && answer['noul'] is num ? _score(answer['noul'] as num) : answer == null && !e.pending ? phase : _answer(answer, entry.value)}',
            depth + 1,
            question: id,
            kind: ClassificationRowKind.question));
        final q = entry.value;
        if (q is! Map || q['type'] != 'choice' || q['criteria'] is! Map)
          continue;
        final probabilities = answer is Map ? answer['probabilities'] : null;
        for (final option in (q['criteria'] as Map).entries) {
          final value = option.value,
              p = probabilities is Map ? probabilities[option.key] : null;
          final label = _name('${option.key}', value);
          final selected = answer is Map && answer['choice'] == option.key;
          rows.add(ClassificationPanelRow(
              e,
              '${selected ? '✓ ' : ''}$label${p is num ? ' · ${_score(p)}' : ''}',
              depth + 2,
              question: id,
              choice: '${option.key}',
              kind: ClassificationRowKind.choice));
        }
      }
    }
    for (final child in exchanges)
      if (child.parentId == e.id && child.inputId == e.inputId)
        visit(child, depth + 1);
  }

  for (final e in exchanges)
    if (!byId.containsKey(e.parentId) || byId[e.parentId]?.inputId != e.inputId)
      visit(e, 0);
  // Malformed/cyclic metadata remains inspectable without recursive loops.
  for (final e in exchanges) if (!visited.contains(e.id)) visit(e, 0);
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
  bool _hierarchy = false, _details = false, _raw = false;
  final _expanded = <int>{};
  int _selected = 0, _offset = 0, _room = 1, _maxOffset = 0, _revision = -1;
  List<ClassificationPanelRow> _rows = [];
  (int, int, (int, String?, String?, ClassificationRowKind))? _detailKey;
  List<String> _detailCache = [];
  (
    int,
    (int, String?, String?, ClassificationRowKind)?,
    ClassificationStatus
  )? _previewKey;
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
    _details = false;
    _raw = false;
    _detailKey = null;
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
        _raw = false;
        _detailKey = null;
        _offset = 0;
        refresh();
      case ArrowKey(direction: ArrowDirection.left):
        _details = false;
        _offset = _selected;
        refresh();
      case CharInput(text: 'h'):
        _hierarchy = !_hierarchy;
        _expanded.clear();
        _details = false;
        _revision = -1;
        _offset = 0;
        refresh();
      case CharInput(text: 'r'):
        if (!_details) break;
        _raw = !_raw;
        _detailKey = null;
        _offset = 0;
        refresh();
      case CharInput(text: ' '):
        if (_details || selected == null) break;
        final id = selected!.exchange.id;
        if (_hierarchy) {
          _expanded.addAll(_rows.map((r) => r.exchange.id));
          _hierarchy = false;
        }
        if (!_expanded.remove(id)) _expanded.add(id);
        _revision = -1;
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
    if (!_raw) {
      final questions = _questions(e), answers = _answers(e);
      final request = _object(e.request);
      final response = _object(e.response);
      final readable = <String>[
        '${_stage(e)} · ${_phase(e)}',
        '',
        'Request',
        if (_input(e) case final String input) 'You asked: $input',
        'Classifier: ${_stage(e)}',
        if (e.trigger != null) 'Trigger: ${e.trigger}',
        if (e.parentId != null)
          for (final parent in plugin.trace.exchanges)
            if (parent.id == e.parentId && parent.inputId == e.inputId)
              'Depends on: ${_stage(parent)}',
        '',
        'Results',
        if (row.question == null) _result(e),
        if (answers.isEmpty)
          e.pending ? 'Waiting for result' : 'No question results available.',
        for (final entry in answers.entries)
          if (row.question == null || row.question == entry.key) ...[
            if (row.choice == null)
              '${_name('${entry.key}', questions[entry.key])}: ${_answer(entry.value, questions[entry.key])}',
            if (entry.value case final Map answer)
              if (row.choice != null)
                'Selected: ${answer['choice'] == row.choice ? 'Yes' : 'No'}',
            if (entry.value case final Map answer)
              if (answer['probabilities'] case final Map probabilities)
                for (final option in probabilities.entries)
                  if (row.choice == null || row.choice == option.key)
                    '${answer['choice'] == option.key ? '✓ ' : ''}${_name('${option.key}', _choiceDefinition(questions[entry.key], option.key))}: ${option.value is num ? _percent(option.value as num) : option.value}',
          ],
        if (response['category'] case final Map category) ...[
          'Category: ${category['label'] ?? category['id']}',
          if (category['description'] != null) '${category['description']}',
          if (category['question'] != null) '${category['question']}',
        ],
        if (response['existing_category'] case final String category)
          'Existing category: ${_name(category)}',
        if (e.error != null) 'Error: ${e.error}',
        '',
        'What was checked',
        for (final entry in questions.entries)
          if (row.question == null || row.question == entry.key) ...[
            _name('${entry.key}', entry.value),
            if (entry.value case final Map q) ...[
              if (row.choice == null && q['instructions'] is String)
                '${q['instructions']}',
              if (q['criteria'] case final Map criteria)
                for (final option in criteria.entries)
                  if (row.choice == null || row.choice == option.key) ...[
                    'Option: ${_name('${option.key}', option.value)}',
                    if (option.value is Map &&
                        (option.value as Map)['question'] is String)
                      '${(option.value as Map)['question']}',
                    if (option.value is String) '${option.value}',
                  ],
            ],
          ],
        if (questions.isEmpty)
          'Discover a request category that fits this input.',
        if (request['question'] case final String question) question,
        if (request['categories'] case final List categories)
          for (final category in categories)
            if (category is Map)
              'Existing option: ${_name('${category['id']}')} · ${category['question']}',
        '',
        'Match scores describe how well an option fits the request.',
        'They do not approve or execute actions.',
        'A check mark marks the returned category choice.',
        if (e.title == 'Git operations')
          'Git actions need at least 80% match; ambiguity can still make the result unclear.',
        '',
        'Context used',
        for (final evidence in _evidence(e))
          if (evidence is Map && evidence['text'] != null)
            '${evidence['meaning'] ?? 'Evidence'}: ${evidence['text']}',
        if (_evidence(e).isEmpty) 'No text context available in this record.',
        '',
        'Press r to inspect the raw request and response.',
      ];
      return _detailCache = [
        for (final line in readable) ...wrapDialogText(_safe(line), width),
      ];
    }
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
      'Raw data · input ${_safe(e.inputId)}',
      'Classifier: ${_safe(e.classifierId)}',
      'Run: ${e.id}${e.parentId == null ? '' : ' · parent run ${e.parentId}'}',
      'Request JSON',
      for (final line in _pretty(request).split('\n'))
        ...wrapDialogText(line, width),
      '',
      'Response JSON${e.pending ? ' · Waiting' : ''}',
      for (final line in _pretty(response).split('\n'))
        ...wrapDialogText(line, width),
      if (e.error != null) ...wrapDialogText('Error: ${e.error}', width),
    ];
  }

  List<String> _preview() {
    final exchanges = plugin.trace.exchanges;
    if (exchanges.isEmpty) return [plugin.status.label];
    final latest = exchanges.last;
    final key = (plugin.trace.revision, selected?.key, plugin.status);
    if (_previewKey == key) return _previewCache;
    _previewKey = key;
    final rows = classificationPanelRows(plugin.trace,
        hierarchy: false, inputId: latest.inputId);
    return _previewCache = [
      if (_input(latest) case final String input) 'You asked: $input',
      for (final row in rows) '${'  ' * row.depth.clamp(0, 4)}${row.label}',
    ];
  }

  String _styleLine(String text) {
    final theme = screen.theme.chat;
    final plain = text
        .trimLeft()
        .replaceFirst(RegExp(r'^[›└]\s*'), '')
        .replaceFirst(RegExp(r'^└\s*'), '');
    final lastSeparator = text.lastIndexOf(' · ');
    final suffix = lastSeparator >= 0 ? text.substring(lastSeparator + 3) : '';
    final phase = const {'◌ Running', '✓ Complete', '! Failed', '– Cancelled'}
            .contains(suffix)
        ? suffix
        : '';
    final separator = phase.isEmpty ? -1 : lastSeparator;
    if (plain.startsWith('▸') ||
        plain.startsWith('▾') ||
        phase == '◌ Running' ||
        phase == '✓ Complete' ||
        phase == '! Failed' ||
        phase == '– Cancelled') {
      if (separator < 0 && text.contains(': ')) {
        final split = text.indexOf(': ') + 2;
        final result = text.substring(split);
        final code =
            result.startsWith('?') || result.startsWith('Model choice:')
                ? theme.yellow
                : result.startsWith('!')
                    ? theme.red
                    : result.startsWith('[loading]') || result.startsWith('◌')
                        ? '34'
                        : theme.agentText;
        return '${screen.colorize('1;${theme.cyan}', text.substring(0, split))}${screen.colorize(code, result)}';
      }
      final header = separator >= 0 ? text.substring(0, separator) : text;
      final code = phase == '◌ Running'
          ? '34'
          : phase == '✓ Complete'
              ? theme.green
              : phase == '! Failed'
                  ? theme.red
                  : theme.dim;
      return '${screen.colorize('1;${theme.cyan}', header)}${separator >= 0 ? ' · ${screen.colorize(code, phase)}' : ''}';
    }
    if (plain.startsWith('?') || plain.startsWith('Model choice:'))
      return screen.colorize(theme.yellow, text);
    if (plain.startsWith('!') || plain.startsWith('Error:'))
      return screen.colorize(theme.red, text);
    if (plain.contains('Waiting for result'))
      return screen.colorize('34', text);
    if (plain.startsWith('✓')) return screen.colorize('1', text);
    if (plain.startsWith('Trigger:') ||
        plain.startsWith('Dependency:') ||
        plain.startsWith('You asked:') ||
        plain.contains('% match')) return screen.colorize(theme.dim, text);
    if (const {
      'Request',
      'Results',
      'What was checked',
      'Context used',
      'Request JSON',
      'Response JSON'
    }.contains(plain)) return screen.colorize('1;${theme.cyan}', text);
    return text;
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
      final retained = plugin.trace.exchanges.map((e) => e.id).toSet();
      _expanded.retainWhere(retained.contains);
      _rows = classificationPanelRows(plugin.trace,
          hierarchy: _hierarchy, expanded: _expanded);
      final preserved = _rows.indexWhere((r) => r.key == key);
      _selected = _focused && preserved >= 0
          ? preserved
          : (_rows.length - 1).clamp(0, _rows.length);
      _revision = plugin.trace.revision;
    }
    if (!_focused && _rows.isNotEmpty)
      _selected = _rows
          .lastIndexWhere((r) => r.kind == ClassificationRowKind.classifier);
    final chat = context.chat.bounds;
    _slot?.requestSize(
        height: _focused
            ? chat.height
            : _hierarchy
                ? 14
                : (_preview().length + 3).clamp(8, 14),
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
                      '${i == _selected ? '› ' : '  '}${'  ' * row.depth.clamp(0, 4)}${row.depth > 0 ? '└ ' : ''}${row.label}'
                  ]
            : preview;
    _maxOffset = (content.length - _room).clamp(0, content.length);
    _offset = _focused
        ? _offset.clamp(0, _maxOffset)
        : _hierarchy
            ? _maxOffset
            : 0;
    final footer = _focused
        ? (_details
            ? '↑↓ scroll · ← back · r ${_raw ? 'readable' : 'raw JSON'}'
            : '↑↓ select · Space checks · → details · h all')
        : '/classification inspect · F6 hide';
    String paint(String text) => screen.colorize(
        _focused
            ? screen.theme.chat.cyan
            : _highlighted
                ? screen.theme.chat.yellow
                : screen.theme.chat.dim,
        text);
    String body(String text) {
      final fit = clipDialogText(_safe(text), width);
      return '${paint('│')} ${_styleLine(fit)}${' ' * (width - visibleWidth(fit))} ${paint('│')}';
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
