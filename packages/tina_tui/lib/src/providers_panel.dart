import 'package:tina_console/tina_console.dart';
import 'package:tina_llm/tina_llm.dart';
import 'assembly_config.dart';

enum _Kind {
  search,
  provider,
  key,
  url,
  separator,
  model,
  addModel,
  advanced,
  addProvider
}

typedef _Row = ({_Kind kind, String id, String? model});

/// The legacy settings tree: expand providers, paste a masked credential or
/// endpoint inline, and check individual models. Config ownership stays with
/// the settings document; Escape discards the tree's draft.
final class ProvidersPanel {
  ProvidersPanel(
      {required this.screen,
      required this.readEvent,
      required this.providers,
      required this.descriptors,
      required this.editAdvanced,
      required this.onShow}) {
    _checked.addAll(providers.keys);
    for (final id in _ids) {
      final settings = _settings(id);
      _disabled[id] = providers.containsKey(id)
          ? settings.disabledModels.toSet()
          : _models(id).keys.toSet();
    }
  }
  final Screen screen;
  final Future<InputEvent> Function() readEvent;
  final Map<String, dynamic> providers;
  final List<ProviderDescriptor> descriptors;
  final Future<void> Function(String) editAdvanced;
  final void Function() onShow;
  final _checked = <String>{}, _expanded = <String>{};
  final _disabled = <String, Set<String>>{};
  final _dismissedHint = <String>{};
  late final OverlayRegion _overlay;
  int _focus = 1, _offset = 0;
  String _query = '', _entry = '';
  _Row? _adding;
  bool _open = false;

  List<String> get _ids =>
      {...descriptors.map((d) => d.id), ...providers.keys}.toList();
  ProviderDescriptor? _descriptor(String id) =>
      descriptors.where((d) => d.id == id).firstOrNull;
  Map<String, dynamic> _values(String id) =>
      providers.putIfAbsent(id, () => <String, dynamic>{})
          as Map<String, dynamic>;
  ProviderSettings _settings(String id) => providers[id] is Map<String, dynamic>
      ? ProviderSettings.parse(id, providers[id] as Map<String, dynamic>)
      : const ProviderSettings();
  Map<String, ModelInfo> _models(String id) =>
      {...?_descriptor(id)?.models, ...?_settings(id).models};
  String _name(String id) =>
      (providers[id] as Map?)?['name'] as String? ??
      _descriptor(id)?.name ??
      id;
  String _keyField(String id) =>
      (providers[id] as Map?)?['auth_token'] != null ? 'auth_token' : 'api_key';

  List<_Row> get _rows => [
        (kind: _Kind.search, id: '', model: null),
        for (final id in _ids)
          if ('$id ${_name(id)}'
              .toLowerCase()
              .contains(_query.toLowerCase())) ...[
            (kind: _Kind.provider, id: id, model: null),
            if (_expanded.contains(id)) ...[
              (kind: _Kind.key, id: id, model: null),
              (kind: _Kind.url, id: id, model: null),
              (kind: _Kind.separator, id: id, model: null),
              for (final model in _models(id).keys)
                (kind: _Kind.model, id: id, model: model),
              (kind: _Kind.addModel, id: id, model: null),
              (kind: _Kind.advanced, id: id, model: null),
            ],
          ],
        (kind: _Kind.addProvider, id: '', model: null),
      ];

  Future<bool> run() async {
    _overlay = OverlayRegion(screen, Rect.empty);
    _open = true;
    try {
      while (true) {
        repaint();
        final event = await readEvent();
        if (event is ControlKey && event.code == ControlCode.ctrlC)
          return false;
        if (_adding != null) {
          if (event is EscapeKey) {
            _adding = null;
            _entry = '';
            continue;
          }
          if (event is ControlKey && event.code == ControlCode.enter) {
            final text = _entry.trim();
            final adding = _adding!;
            if (adding.kind == _Kind.addProvider) {
              if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_-]*$').hasMatch(text) ||
                  _ids.contains(text)) continue;
              providers[text] = <String, dynamic>{'wire': 'openai'};
              _checked.add(text);
              _expanded.add(text);
              _disabled[text] = {};
              _query = '';
              _focus = _rows
                  .indexWhere((r) => r.id == text && r.kind == _Kind.provider);
            } else {
              if (text.isEmpty || text.split('|').first.trim().isEmpty)
                continue;
              final values = _values(adding.id);
              final models = List<String>.from(values['models'] as List? ?? []);
              final id = text.split('|').first.trim();
              models.removeWhere((m) => m.split('|').first.trim() == id);
              values['models'] = [...models, text];
              _checked.add(adding.id);
              _disabled[adding.id]!.remove(id);
            }
            _adding = null;
            _entry = '';
            continue;
          }
          _entry = _editText(_entry, event);
          continue;
        }
        if (event is EscapeKey) return false;
        final rows = _rows;
        _focus = _focus.clamp(0, rows.length - 1);
        final row = rows[_focus];
        if (event is ArrowKey) {
          switch (event.direction) {
            case ArrowDirection.up:
              _focus = (_focus - 1).clamp(0, rows.length - 1);
            case ArrowDirection.down:
              _focus = (_focus + 1).clamp(0, rows.length - 1);
            case ArrowDirection.pageUp:
              _focus = (_focus - _room).clamp(0, rows.length - 1);
            case ArrowDirection.pageDown:
              _focus = (_focus + _room).clamp(0, rows.length - 1);
            case ArrowDirection.right:
              if (row.kind == _Kind.provider) _expanded.add(row.id);
            case ArrowDirection.left:
              if (row.kind == _Kind.provider) {
                _expanded.remove(row.id);
              } else if (row.id.isNotEmpty) {
                _focus = rows.indexWhere(
                    (r) => r.kind == _Kind.provider && r.id == row.id);
              }
          }
          continue;
        }
        if (row.kind == _Kind.search) {
          _query = _editText(_query, event);
          _offset = 0;
          continue;
        }
        if (row.kind == _Kind.key || row.kind == _Kind.url) {
          if (event is CharInput ||
              event is PasteInput ||
              event is EditingKey ||
              event is ControlKey && event.code == ControlCode.backspace) {
            final field =
                row.kind == _Kind.key ? _keyField(row.id) : 'base_url';
            final values = _values(row.id);
            final old = values[field] as String? ?? '';
            final next = _editText(old, event);
            if (next.isEmpty)
              values.remove(field);
            else
              values[field] = next;
            if (next != old) _checked.add(row.id);
            if (row.kind == _Kind.key) _dismissedHint.add(row.id);
            continue;
          }
        }
        if (event is CharInput && event.text == ' ') {
          if (row.kind == _Kind.provider) {
            if (!_checked.add(row.id)) {
              _checked.remove(row.id);
              _expanded.remove(row.id);
            }
          } else if (row.kind == _Kind.model) {
            final disabled = _disabled[row.id]!;
            if (!disabled.add(row.model!)) {
              disabled.remove(row.model);
              _checked.add(row.id);
            }
          }
          continue;
        }
        if (event is ControlKey && event.code == ControlCode.enter) {
          if (row.kind == _Kind.addModel || row.kind == _Kind.addProvider) {
            _adding = row;
            _entry = '';
            continue;
          }
          if (row.kind == _Kind.advanced) {
            _overlay.hide();
            _checked.add(row.id);
            _values(row.id);
            await editAdvanced(row.id);
            _disabled[row.id] = _settings(row.id).disabledModels.toSet();
            continue;
          }
          for (final id in _checked) {
            _values(id)['disabled_models'] = _disabled[id]!.toList();
          }
          providers.removeWhere((id, _) => !_checked.contains(id));
          return true;
        }
      }
    } finally {
      _open = false;
      _overlay.hide();
      _overlay.dispose();
    }
  }

  int get _room => (_height - 4).clamp(1, 10000);
  int get _height {
    final height = dialogArea(screen.layout).height;
    return (height ~/ 2).clamp(height < 12 ? height : 12, height);
  }

  void repaint() {
    if (!_open) return;
    onShow();
    final area = dialogArea(screen.layout);
    final width = (area.width - 4)
        .clamp(area.width < 40 ? area.width : 40, area.width.clamp(0, 70));
    final height = _height;
    final rows = _rows;
    _focus = _focus.clamp(0, rows.length - 1);
    if (_focus < _offset) _offset = _focus;
    if (_focus >= _offset + _room) _offset = _focus - _room + 1;
    _offset = _offset.clamp(0, (rows.length - _room).clamp(0, rows.length));
    final lines = <String>[];
    for (var i = _offset; i < rows.length && i < _offset + _room; i++) {
      final row = rows[i], focused = i == _focus;
      final text = switch (row.kind) {
        _Kind.search =>
          '  / ${_query.isEmpty && !focused ? '(type to filter providers)' : _query}${focused ? '▏' : ''}',
        _Kind.provider =>
          '${_checked.contains(row.id) ? '☑' : '☐'} ${_name(row.id)}',
        _Kind.key => _credential(row.id, focused),
        _Kind.url => _url(row.id, focused),
        _Kind.separator => '  ── models ──',
        _Kind.model =>
          '  ${_disabled[row.id]!.contains(row.model) ? '☐' : '☑'} ${_models(row.id)[row.model]!.name}',
        _Kind.addModel =>
          _adding == row ? '  ＋ $_entry▏' : '  ＋ add model id (or id|Name)',
        _Kind.advanced => '  Advanced settings…',
        _Kind.addProvider => _adding == row ? '＋ $_entry▏' : '＋ add provider',
      };
      final marker = focused
          ? '❯'
          : row.kind == _Kind.provider
              ? _expanded.contains(row.id)
                  ? '▾'
                  : '▸'
              : ' ';
      final shown = '$marker $text';
      lines.add(
          focused ? screen.colorize(screen.theme.border.focus, shown) : shown);
    }
    _overlay.update(
        bounds: Rect(
            row: area.row + (area.height - height) ~/ 2,
            col: area.col + (area.width - width) ~/ 2,
            width: width,
            height: height),
        lines: dialogBoxLines(
            width: width,
            height: height,
            title: 'Providers & models',
            body: lines,
            footer:
                '↑↓ move · → expand · ← collapse · space toggle · enter apply · esc cancel',
            paint: (text) => screen.colorize(screen.theme.border.focus, text)));
  }

  String _credential(String id, bool focused) {
    final field = _keyField(id);
    final key = (providers[id] as Map?)?[field] as String? ?? '';
    final env = _descriptor(id)?.keyEnvVar ?? '';
    final hint = key.isEmpty && !_dismissedHint.contains(id) && env.isNotEmpty
        ? '(or env $env)'
        : '';
    return '  ${field == 'auth_token' ? 'Auth token' : 'API key'}: ${'*' * key.length}$hint${focused ? '_' : ''}';
  }

  String _url(String id, bool focused) {
    final url = (providers[id] as Map?)?['base_url'] as String? ?? '';
    return '  Base URL: ${url.isEmpty ? '(default: ${_descriptor(id)?.baseUrl ?? 'none'})' : url}${focused ? '_' : ''}';
  }

  String _editText(String old, InputEvent event) => switch (event) {
        CharInput(:final text) ||
        PasteInput(:final text) =>
          old + text.replaceAll(RegExp(r'[\x00-\x1f\x7f-\x9f]'), ''),
        ControlKey(code: ControlCode.backspace) ||
        EditingKey(action: EditingAction.delete) =>
          old.isEmpty
              ? old
              : String.fromCharCodes(old.runes.toList()..removeLast()),
        EditingKey(
          action: EditingAction.killToStart || EditingAction.killToEnd
        ) =>
          '',
        _ => old,
      };
}
