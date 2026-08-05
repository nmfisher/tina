import 'dart:io';

import 'package:tina/config/setup.dart';
import 'package:tina/config/user_config.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';

/// The first-run setup overlay / /settings panel: a modal that collects
/// provider/model/key configuration via an expandable provider tree, then
/// separate heavy/light tier model selection, token limits, and confirm.
///
/// Flow: providers (tree) → heavy → light → limits (/settings only) → confirm.
/// Returns the written [UserConfig] on confirm, or `null` on cancel.
///
/// Driven by [LineEditor.readKey] (the proven exclusive-capture path also used
/// by the permission modal). [readEvent] is injectable so tests can feed
/// canned [InputEvent]s without a real terminal.
Future<UserConfig?> runSetupOverlay({
  required Screen screen,
  required LineEditor editor,
  required ProviderRegistry registry,
  required Map<String, String> env,
  Directory? tinaDir,
  Future<InputEvent> Function()? readEvent,
  UserConfig? initial,
}) {
  return _SetupForm(
    screen,
    registry,
    env,
    tinaDir,
    readEvent ?? editor.readKey,
    initial,
  ).run();
}

// -- Step & constants -------------------------------------------------------

enum _Step { providers, heavy, light, limits, theme, confirm }
enum _Result { changed, wrote, cancelled }

const _checkOff = '☐';
const _checkOn = '☑';
const _focusMark = '▸';
const _indent = '  '; // 2-space indent for sub-items
const _skipLabel = '(skip — no light tier)';

// -- Row data model ---------------------------------------------------------

enum _RowType { provider, key, url, separator, model }

/// One visible row in the provider tree view. The flat list is recomputed
/// from state each frame via [_SetupForm._computeRows].
class _Row {
  final _RowType type;
  final int providerIndex; // index into _providerIds
  final int? modelIndex; // index into registry.modelsFor(providerId)

  /// [emptyModels] is a sentinel — true only for the placeholder row that
  /// replaces the separator when a provider has no known models.
  final bool emptyModels;
  const _Row(this.type, this.providerIndex, this.modelIndex,
      {this.emptyModels = false});
}

// -- Form class -------------------------------------------------------------

class _SetupForm {
  _SetupForm(
    this._screen,
    this._registry,
    this._env,
    this._tinaDir,
    this._readEvent, [
    UserConfig? initial,
  ]) : _initialProviders = initial?.providers {
    if (initial != null) {
      _checked.addAll(initial.providers.keys);
      for (final e in initial.providers.entries) {
        final k = e.value.apiKey;
        if (k != null && k.isNotEmpty) _keys[e.key] = k;
        final u = e.value.baseUrl;
        if (u != null && u.isNotEmpty) _baseUrls[e.key] = u;
        // Seed disabled models from the saved config.
        for (final mid in (e.value.disabledModels ?? const <String>[])) {
          _disabledModels.add('${e.key}/$mid');
        }
      }
      _heavy = initial.tiers['heavy'];
      _light = initial.tiers['light'];
      _themeVariant = initial.themeVariant;
    }
    _showLimits = initial != null;
    _initialLimits = initial?.limits;
  }

  final Screen _screen;
  final ProviderRegistry _registry;
  final Map<String, String> _env;
  final Directory? _tinaDir;
  final Future<InputEvent> Function() _readEvent;

  late final OverlayRegion _overlay;
  late final Rect _rect;

  // -- Provider-tree state --------------------------------------------------

  final _checked = <String>{};
  final _keys = <String, String>{};
  final _baseUrls = <String, String>{};
  final Map<String, ProviderConfig>? _initialProviders;
  final _expanded = <String>{}; // provider ids whose sub-items are visible
  final _disabledModels = <String>{}; // "provider/model" refs the user unchecked
  int _focus = 0;
  int _scrollOffset = 0; // first visible row index in the providers tree

  // -- Tier selection state -------------------------------------------------

  String? _heavy; // "provider/model"
  String? _light; // null = light tier skipped
  List<String> _modelOptions = const [];
  bool _lightSkippable = false;
  String _skipLabelCurrent = _skipLabel;

  // -- Theme variant state ----------------------------------------------------
  String? _themeVariant; // null=system, 'dark', 'light'

  // -- Limits-step state (/settings only) -----------------------------------

  late final bool _showLimits;
  late final LimitsConfig? _initialLimits;
  final _limitIds = <String>[];
  final _limitLabels = <String>[];
  final _limitValues = <String, int>{};
  int _limitFocus = 0;

  // -------------------------------------------------------------------------

  _Step _step = _Step.providers;
  UserConfig? _written;
  String? _writeError; // set when a confirm-time write failed (e.g. read-only)

  List<String> get _providerIds => _registry.providerIds;

  // -- Run loop -------------------------------------------------------------

  Future<UserConfig?> run() async {
    final layout = _screen.layout;
    final w = (layout.width - 4).clamp(40, 70);
    final h = (layout.height ~/ 2).clamp(12, layout.height - 4);
    _rect = Rect(
      row: (layout.height - h) ~/ 2,
      col: (layout.width - w) ~/ 2,
      width: w,
      height: h,
    );
    _overlay = OverlayRegion(_screen, _rect);
    _render();
    while (true) {
      final ev = await _readEvent();
      if (ev is EscapeKey ||
          (ev is ControlKey && ev.code == ControlCode.ctrlC)) {
        if (!_back()) {
          _dispose();
          return null;
        }
        _render();
        continue;
      }
      switch (_dispatch(ev)) {
        case _Result.changed:
          _render();
        case _Result.wrote:
          _dispose();
          return _written;
        case _Result.cancelled:
          _dispose();
          return null;
      }
    }
  }

  void _dispose() {
    _overlay.hide();
    _overlay.dispose();
  }

  // -- Dispatch -------------------------------------------------------------

  _Result _dispatch(InputEvent ev) {
    switch (_step) {
      case _Step.providers:
        return _onProviders(ev);
      case _Step.heavy:
        return _onPick(ev, (ref) {
          _heavy = ref;
          _enterLightStep();
          return _Result.changed;
        });
      case _Step.light:
        return _onPick(ev, (ref) {
          _light = ref;
          _enterThemeStep();
          return _Result.changed;
        });
      case _Step.theme:
        return _onPick(ev, (ref) {
          _themeVariant = ref;
          _enterConfirmOrLimits();
          return _Result.changed;
        });
      case _Step.limits:
        return _onLimits(ev);
      case _Step.confirm:
        return _onConfirm(ev);
    }
  }

  // -- Row computation (provider tree) --------------------------------------

  /// Build the flat row list from current provider-tree state. Collapsed
  /// providers produce a single row; expanded providers inject key, URL,
  /// separator, and model sub-rows.
  List<_Row> _computeRows() {
    final rows = <_Row>[];
    for (var pi = 0; pi < _providerIds.length; pi++) {
      rows.add(_Row(_RowType.provider, pi, null));
      if (_expanded.contains(_providerIds[pi])) {
        if (_requiresKey(_providerIds[pi])) {
          rows.add(_Row(_RowType.key, pi, null));
          rows.add(_Row(_RowType.url, pi, null));
        }
        rows.add(_Row(_RowType.separator, pi, null));
        final models = _registry.modelsFor(_providerIds[pi]);
        if (models.isEmpty) {
          rows.add(_Row(_RowType.separator, pi, null, emptyModels: true));
        } else {
          for (var mi = 0; mi < models.length; mi++) {
            rows.add(_Row(_RowType.model, pi, mi));
          }
        }
      }
    }
    return rows;
  }

  // -- Provider tree dispatch -----------------------------------------------

  _Result _onProviders(InputEvent ev) {
    final rows = _computeRows();
    if (_focus >= rows.length && rows.isNotEmpty) _focus = rows.length - 1;
    if (rows.isEmpty) return _Result.changed;

    final f = rows[_focus];

    // Arrow keys.
    if (ev is ArrowKey) {
      final page = _rect.height - 4;
      switch (ev.direction) {
        case ArrowDirection.up:
        case ArrowDirection.down:
          final d = ev.direction == ArrowDirection.up ? -1 : 1;
          _focus = (_focus + d).clamp(0, rows.length - 1);
          _ensureFocusVisible(rows.length);
          return _Result.changed;
        case ArrowDirection.pageUp:
          _focus = (_focus - page).clamp(0, rows.length - 1);
          _ensureFocusVisible(rows.length);
          return _Result.changed;
        case ArrowDirection.pageDown:
          _focus = (_focus + page).clamp(0, rows.length - 1);
          _ensureFocusVisible(rows.length);
          return _Result.changed;
        case ArrowDirection.right:
          if (f.type == _RowType.provider) {
            _expanded.add(_providerIds[f.providerIndex]);
            _ensureFocusVisible(rows.length);
            return _Result.changed;
          }
          return _Result.changed;
        case ArrowDirection.left:
          if (f.type == _RowType.provider) {
            _expanded.remove(_providerIds[f.providerIndex]);
          } else {
            _focus = _parentProviderIndex(rows, _focus);
          }
          _ensureFocusVisible(rows.length);
          return _Result.changed;
      }
    }

    // Backspace on key/URL fields.
    if (ev is ControlKey && ev.code == ControlCode.backspace) {
      if (f.type == _RowType.key || f.type == _RowType.url) {
        _backspaceField(f);
      }
      return _Result.changed;
    }

    // CharInput.
    if (ev is CharInput) {
      final c = ev.text;

      // Key/URL typing.
      if (f.type == _RowType.key || f.type == _RowType.url) {
        _appendField(f, c);
        return _Result.changed;
      }

      // Space toggles provider checkbox or model availability.
      if (c == ' ') {
        if (f.type == _RowType.provider) {
          _toggle(_providerIds[f.providerIndex]);
          return _Result.changed;
        }
        if (f.type == _RowType.model && f.modelIndex != null) {
          _toggleModel(f);
          return _Result.changed;
        }
      }

      return _Result.changed;
    }

    // Enter: advance to heavy tier selection.
    if (ev is ControlKey && ev.code == ControlCode.enter) {
      if (_checked.isEmpty) return _Result.changed;
      _enterHeavyStep();
      return _Result.changed;
    }

    return _Result.changed;
  }

  /// Adjust [_scrollOffset] so the focused row stays within the visible
  /// window of the providers tree.
  void _ensureFocusVisible(int totalRows) {
    final visibleRows = (_rect.height - 4).clamp(1, totalRows);
    if (_focus < _scrollOffset) {
      _scrollOffset = _focus;
    } else if (_focus >= _scrollOffset + visibleRows) {
      _scrollOffset = _focus - visibleRows + 1;
    }
  }

  // -- Field editing helpers ------------------------------------------------

  void _appendField(_Row f, String c) {
    final id = _providerIds[f.providerIndex];
    if (f.type == _RowType.key) {
      _keys[id] = (_keys[id] ?? '') + c;
    } else {
      _baseUrls[id] = (_baseUrls[id] ?? '') + c;
    }
  }

  void _backspaceField(_Row f) {
    final id = _providerIds[f.providerIndex];
    if (f.type == _RowType.key) {
      final v = _keys[id] ?? '';
      if (v.isNotEmpty) _keys[id] = v.substring(0, v.length - 1);
    } else {
      final v = _baseUrls[id] ?? '';
      if (v.isNotEmpty) _baseUrls[id] = v.substring(0, v.length - 1);
    }
  }

  int _parentProviderIndex(List<_Row> rows, int focus) {
    for (var i = focus - 1; i >= 0; i--) {
      if (rows[i].type == _RowType.provider) return i;
    }
    return 0;
  }

  // -- Tier selection -------------------------------------------------------

  /// All `"provider/model"` refs from checked providers, in registry order.
  List<String> _candidates() => [
        for (final id in _providerIds)
          if (_checked.contains(id))
            for (final m in _registry.modelsFor(id)) '$id/${m.id}',
      ];

  void _enterHeavyStep() {
    _modelOptions = _candidates();
    _lightSkippable = false;
    if (_modelOptions.isEmpty) {
      // No models from any checked provider — skip tiers entirely.
      _heavy = null;
      _light = null;
      _focus = 0;
      _step = _Step.confirm;
    } else {
      final idx = _heavy == null ? -1 : _modelOptions.indexOf(_heavy!);
      _focus = idx < 0 ? 0 : idx;
      _step = _Step.heavy;
    }
  }

  void _enterLightStep() {
    _modelOptions = _candidates();
    _lightSkippable = true;
    _skipLabelCurrent = _skipLabel;
    var idx = 0; // skip row
    if (_light != null) {
      final m = _modelOptions.indexOf(_light!);
      if (m >= 0) idx = m + 1;
    }
    _focus = idx;
    _step = _Step.light;
  }

  void _enterThemeStep() {
    _modelOptions = const ['dark', 'light'];
    _lightSkippable = true;
    _skipLabelCurrent = 'System theme';
    var idx = 0; // first row = "System theme" → null
    if (_themeVariant == 'dark') idx = 1;
    if (_themeVariant == 'light') idx = 2;
    _focus = idx;
    _step = _Step.theme;
  }

  void _enterConfirmOrLimits() {
    _focus = 0;
    _writeError = null;
    if (_showLimits) {
      _enterLimitsStep();
    } else {
      _step = _Step.confirm;
    }
  }

  _Result _onPick(InputEvent ev, _Result Function(String?) chosen) {
    final opts = [..._if(_lightSkippable, _skipLabelCurrent), ..._modelOptions];
    if (opts.isEmpty) return chosen(null);
    if (ev is ArrowKey) {
      final page = _rect.height - 4;
      switch (ev.direction) {
        case ArrowDirection.up:
          _focus = (_focus - 1).clamp(0, opts.length - 1);
          return _Result.changed;
        case ArrowDirection.down:
          _focus = (_focus + 1).clamp(0, opts.length - 1);
          return _Result.changed;
        case ArrowDirection.pageUp:
          _focus = (_focus - page).clamp(0, opts.length - 1);
          return _Result.changed;
        case ArrowDirection.pageDown:
          _focus = (_focus + page).clamp(0, opts.length - 1);
          return _Result.changed;
        case ArrowDirection.left:
        case ArrowDirection.right:
          return _Result.changed;
      }
    }
    if (ev is ControlKey && ev.code == ControlCode.enter) {
      final idx = _focus;
      if (_lightSkippable && idx == 0) return chosen(null);
      final adj = _lightSkippable ? idx - 1 : idx;
      return chosen(_modelOptions[adj]);
    }
    return _Result.changed;
  }

  // -- Limits step ----------------------------------------------------------

  void _enterLimitsStep() {
    if (_limitIds.isEmpty) {
      _limitIds.addAll(const [
        'max_session_tokens',
        'max_turn_tokens',
        'max_request_tokens',
        'max_global_tokens',
        'max_sub_agent_tokens',
        'requests_per_minute',
      ]);
      _limitLabels.addAll(const [
        'Session tokens',
        'Turn tokens',
        'Request tokens',
        'Global tokens',
        'Sub-agent tokens',
        'Requests / minute',
      ]);
      final f = _initialLimits ?? const LimitsConfig();
      _limitValues['max_session_tokens'] = f.maxSessionTokens ?? 10000000;
      _limitValues['max_turn_tokens'] = f.maxTurnTokens ?? 1000000;
      _limitValues['max_request_tokens'] = f.maxRequestTokens ?? 200000;
      _limitValues['max_global_tokens'] = f.maxGlobalTokens ?? 50000000;
      _limitValues['max_sub_agent_tokens'] = f.maxSubAgentTokens ?? 2000000;
      _limitValues['requests_per_minute'] = f.requestsPerMinute ?? 0;
    }
    _limitFocus = 0;
    _step = _Step.limits;
  }

  _Result _onLimits(InputEvent ev) {
    if (ev is ControlKey && ev.code == ControlCode.enter) {
      _step = _Step.confirm;
      _focus = 0;
      return _Result.changed;
    }
    if (ev is ControlKey && ev.code == ControlCode.backspace) {
      final id = _limitIds[_limitFocus];
      _limitValues[id] = _limitValues[id]! ~/ 10;
      return _Result.changed;
    }
    if (ev is ArrowKey) {
      final page = _rect.height - 4;
      switch (ev.direction) {
        case ArrowDirection.up:
          _limitFocus = (_limitFocus - 1).clamp(0, _limitIds.length - 1);
          return _Result.changed;
        case ArrowDirection.down:
          _limitFocus = (_limitFocus + 1).clamp(0, _limitIds.length - 1);
          return _Result.changed;
        case ArrowDirection.pageUp:
          _limitFocus = (_limitFocus - page).clamp(0, _limitIds.length - 1);
          return _Result.changed;
        case ArrowDirection.pageDown:
          _limitFocus = (_limitFocus + page).clamp(0, _limitIds.length - 1);
          return _Result.changed;
        case ArrowDirection.left:
        case ArrowDirection.right:
          return _Result.changed;
      }
    }
    if (ev is CharInput && ev.text.length == 1) {
      final c = ev.text.codeUnitAt(0);
      if (c >= 48 && c <= 57) {
        final digit = c - 48;
        final id = _limitIds[_limitFocus];
        final v = _limitValues[id]!;
        if (v == 0) {
          _limitValues[id] = digit;
        } else if ('$v'.length < 12) {
          _limitValues[id] = int.parse('$v$digit');
        }
        return _Result.changed;
      }
    }
    return _Result.changed;
  }

  // -- Confirm step ---------------------------------------------------------

  _Result _onConfirm(InputEvent ev) {
    if (ev is ControlKey && ev.code == ControlCode.enter) {
      final r = _write();
      if (r.error != null) {
        // Stay on the confirm step and show why the write failed (e.g. config
        // is on a read-only mount). The user can Esc back or cancel.
        _writeError = r.error;
        return _Result.changed;
      }
      _written = r.config;
      return _Result.wrote;
    }
    return _Result.changed;
  }

  // -- Helpers --------------------------------------------------------------

  void _toggle(String id) {
    if (!_checked.add(id)) {
      _checked.remove(id);
      _expanded.remove(id);
      _keys.remove(id);
      _baseUrls.remove(id);
      if (_heavy != null && _heavy!.startsWith('$id/')) _heavy = null;
      if (_light != null && _light!.startsWith('$id/')) _light = null;
    } else {
      // When a provider is first enabled, all its models start available.
      // Clear any stale disabled entries for this provider.
      _disabledModels.removeWhere((ref) => ref.startsWith('$id/'));
    }
  }

  /// Toggle whether a model is available (checked) for `/spawn`. Disabled models
  /// are stored as `"provider/model"` refs in [_disabledModels].
  void _toggleModel(_Row f) {
    final id = _providerIds[f.providerIndex];
    final models = _registry.modelsFor(id);
    if (f.modelIndex! >= models.length) return;
    final ref = '$id/${models[f.modelIndex!].id}';
    if (!_disabledModels.add(ref)) {
      // Was already disabled → re-enable. Also ensures the provider is checked
      // so a re-enabled model doesn't sit under an unchecked provider.
      _disabledModels.remove(ref);
      _checked.add(id);
    }
  }

  bool _requiresKey(String id) {
    final desc = _registry.descriptor(id);
    return desc != null && !_registry.isAuthOptional(desc);
  }

  // -- Back navigation ------------------------------------------------------

  bool _back() {
    switch (_step) {
      case _Step.providers:
        return false;

      case _Step.heavy:
        _step = _Step.providers;
        return true;

      case _Step.light:
        _enterHeavyStep();
        return true;

      case _Step.theme:
        _enterLightStep();
        return true;

      case _Step.limits:
        _enterThemeStep();
        return true;

      case _Step.confirm:
        if (_showLimits) {
          _enterLimitsStep();
        } else {
          _step = _Step.theme;
          _focus = 0;
        }
        return true;
    }
  }

  // -- Write ----------------------------------------------------------------

  ({UserConfig? config, String? error}) _write() {
    final tiers = <String, String>{};
    if (_heavy != null) tiers['heavy'] = _heavy!;
    if (_light != null) tiers['light'] = _light!;
    final LimitsConfig? limits = _showLimits && _limitIds.isNotEmpty
        ? LimitsConfig(
            maxSessionTokens: _limitValues['max_session_tokens'],
            maxTurnTokens: _limitValues['max_turn_tokens'],
            maxRequestTokens: _limitValues['max_request_tokens'],
            maxGlobalTokens: _limitValues['max_global_tokens'],
            maxSubAgentTokens: _limitValues['max_sub_agent_tokens'],
            requestsPerMinute: _limitValues['requests_per_minute'],
          )
        : null;
    final filteredKeys = <String, String>{
      for (final id in _checked)
        if (_keys.containsKey(id)) id: _keys[id]!,
    };
    final filteredBaseUrls = <String, String>{
      for (final id in _checked)
        if (_baseUrls.containsKey(id)) id: _baseUrls[id]!,
    };
    // Build per-provider disabled model ids from the flat ref set.
    final dis = <String, Set<String>>{};
    for (final ref in _disabledModels) {
      final slash = ref.indexOf('/');
      if (slash < 0) continue;
      final pid = ref.substring(0, slash);
      final mid = ref.substring(slash + 1);
      dis.putIfAbsent(pid, () => <String>{}).add(mid);
    }
    final cfg = buildSetupConfig(
      tiers: tiers,
      keys: filteredKeys,
      limits: limits,
      existingProviders: _initialProviders,
      baseUrls: filteredBaseUrls,
      disabledModels: dis,
      themeVariant: _themeVariant,
    );
    try {
      writeUserConfig(cfg, env: _env, tinaDir: _tinaDir);
      return (config: cfg, error: null);
    } on ConfigWriteException catch (e) {
      return (config: null, error: e.toString());
    }
  }

  // -- Render ---------------------------------------------------------------

  void _render() => _overlay.show(_box(_title(), _body(), _footer()));

  String _title() {
    switch (_step) {
      case _Step.providers:
        return 'Configure providers';
      case _Step.heavy:
        return 'Choose heavy model';
      case _Step.light:
        return 'Choose light model';
      case _Step.limits:
        return 'Token limits';
      case _Step.theme:
        return 'Choose theme';
      case _Step.confirm:
        return 'Confirm';
    }
  }

  List<String> _body() {
    switch (_step) {
      case _Step.providers:
        return _providersBody();
      case _Step.heavy:
      case _Step.light:
        final tier = _step == _Step.heavy ? 'heavy' : 'light';
        final opts = [..._if(_lightSkippable, _skipLabel), ..._modelOptions];
        return [
          'Model for the "$tier" tier:',
          for (var i = 0; i < opts.length; i++) _row(i == _focus, opts[i]),
        ];
      case _Step.theme:
        final opts = ['System theme', 'Dark theme', 'Light theme'];
        return [
          'Color theme:',
          for (var i = 0; i < opts.length; i++) _row(i == _focus, opts[i]),
        ];
      case _Step.limits:
        return [
          'Token limits (0 = unlimited):',
          for (var i = 0; i < _limitIds.length; i++)
            _row(i == _limitFocus,
                '${_limitLabels[i]}: ${_limitValues[_limitIds[i]]}'),
        ];
      case _Step.confirm:
        return _confirmBody();
    }
  }

  String get _themeLabel {
    switch (_themeVariant) {
      case 'dark':
        return 'Dark';
      case 'light':
        return 'Light';
      default:
        return 'System';
    }
  }

  List<String> _confirmBody() {
    return [
      if (_writeError != null) _row(false, '⚠ $_writeError'),
      _row(false, 'default:  ${_heavy ?? "(none)"}'),
      _row(false, 'light:    ${_light ?? "(none)"}'),
      _row(false, 'theme:    $_themeLabel'),
      for (final id in _checked)
        _row(false, '$id: ${_keys.containsKey(id) ? "key set" : "no key"}'
            '${_baseUrls.containsKey(id) ? " + custom base URL" : ""}'),
      if (_showLimits && _limitIds.isNotEmpty)
        for (var i = 0; i < _limitIds.length; i++)
          _row(false, '${_limitLabels[i]}: ${_limitValues[_limitIds[i]]}'),
    ];
  }

  /// Render the provider tree view, scrolled so [_focus] is visible.
  /// Shows ↑/↓ indicators on the first/last row when content overflows.
  List<String> _providersBody() {
    final rows = _computeRows();
    if (_focus >= rows.length && rows.isNotEmpty) _focus = rows.length - 1;
    if (_focus < 0 || rows.isEmpty) return [];

    final visibleRows = (_rect.height - 4).clamp(1, rows.length);
    _scrollOffset = _scrollOffset.clamp(0, rows.length - 1);
    final end = (_scrollOffset + visibleRows).clamp(0, rows.length);
    final slice = rows.sublist(_scrollOffset, end);

    final hasAbove = _scrollOffset > 0;
    final hasBelow = end < rows.length;

    final lines = <String>[];
    for (var i = 0; i < slice.length; i++) {
      final r = slice[i];
      final focused = (_scrollOffset + i) == _focus;
      switch (r.type) {
        case _RowType.provider:
          final id = _providerIds[r.providerIndex];
          final check = _checked.contains(id) ? _checkOn : _checkOff;
          final arrow = _expanded.contains(id) ? '▼' : '▸';
          final label = _registry.descriptor(id)?.name ?? id;
          lines.add(_row(focused, '$check $arrow $label'));
        case _RowType.key:
          final id = _providerIds[r.providerIndex];
          final k = _keys[id] ?? '';
          final cursor = focused ? '_' : ' ';
          lines.add(_row(focused,
              '${_indent}API key: ${'*' * k.length}$cursor'));
        case _RowType.url:
          final id = _providerIds[r.providerIndex];
          final u = _baseUrls[id] ?? '';
          final cursor = focused ? '_' : ' ';
          lines.add(_row(focused, '${_indent}Base URL: $u$cursor'));
        case _RowType.separator:
          if (r.emptyModels) {
            lines.add(_row(false, '${_indent}(no known models)'));
          } else {
            lines.add(_row(false, '${_indent}── models ──'));
          }
        case _RowType.model:
          final id = _providerIds[r.providerIndex];
          final models = _registry.modelsFor(id);
          if (r.modelIndex! < models.length) {
            final ref = '$id/${models[r.modelIndex!].id}';
            final check = _disabledModels.contains(ref) ? _checkOff : _checkOn;
            lines.add(_row(focused,
                '${_indent}$check ${models[r.modelIndex!].name}'));
          }
      }
    }

    // Overlay scroll indicators on the edge rows instead of the real
    // content behind them — the content is one scroll-step away.
    if (hasBelow && lines.length > 0) {
      final nBelow = rows.length - _scrollOffset - slice.length;
      lines[lines.length - 1] = _row(false, '${_indent}↓ $nBelow more');
    }
    if (hasAbove && lines.length > 0) {
      final nAbove = _scrollOffset;
      lines[0] = _row(false, '${_indent}↑ $nAbove more');
    }

    // Catalog load warning (e.g. models.dev fetch failed). Shown as a
    // non-scrollable row at the end of the tree.
    final warning = _registry.catalog?.loadWarning;
    if (warning != null) {
      lines.add(_row(false, ' ⚠ $warning'));
    }
    return lines;
  }

  String _footer() {
    switch (_step) {
      case _Step.providers:
        return '↑↓ move · → expand · ← collapse · space toggle provider/model · enter continue';
      case _Step.heavy:
      case _Step.light:
      case _Step.theme:
        return '↑↓ move · enter select';
      case _Step.limits:
        return '↑↓ move · digits edit · backspace del · enter ok';
      case _Step.confirm:
        return 'enter write · esc back';
    }
  }

  String _row(bool focused, String text) =>
      '${focused ? _focusMark : ' '} $text';

  // Conditional collection literal helper — Dart 3's collection-if isn't
  // usable inline inside switch expressions or list concatenations without
  // redundant wrappers, so this simplifies [_if(condition), ...list].
  static List<T> _if<T>(bool condition, [T? value]) =>
      condition && value != null ? [value] : <T>[];

  // -- Box renderer ---------------------------------------------------------

  List<String> _box(String title, List<String> body, String footer) {
    final w = _rect.width;
    final innerW = w - 4;
    String wrap(String s) {
      final t = s.length > innerW ? s.substring(0, innerW) : s.padRight(innerW);
      return '│ $t │';
    }

    final titleSeg = ' $title ';
    final titleFit =
        titleSeg.length > w - 2 ? titleSeg.substring(0, w - 2) : titleSeg;
    final lines = <String>[
      '┌$titleFit${'─' * (w - 2 - titleFit.length)}┐',
      ...body.map(wrap),
      wrap(''),
      wrap(footer),
    ];
    while (lines.length < _rect.height - 1) {
      lines.add(wrap(''));
    }
    lines.add('└${'─' * (w - 2)}┘');
    if (lines.length > _rect.height) {
      lines.removeRange(_rect.height, lines.length);
    }
    return lines;
  }
}
