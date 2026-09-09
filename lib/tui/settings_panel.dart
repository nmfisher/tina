import 'dart:io';

import 'package:tina/config/provider_selection.dart';
import 'package:tina/config/user_config.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';

import 'spawn_overlay.dart';

/// The active-surface border color. A modal is the single blue panel while it is
/// the topmost shown surface, so the accent is always the focus (cyan) border —
/// see `ConversationPanel._accent` for the equivalent on conversation panels.
String activeAccent(Screen screen) => screen.theme.border.focus;

/// The `/settings` surface: an index menu that dispatches to independently-
/// saved subpanels. Unlike the first-run wizard ([runSetupOverlay], a linear
/// `providers → heavy → light → limits → theme → confirm` machine that writes
/// everything once at the end), each subpanel owns one config slice and saves it
/// on its own exit — so opening settings to change one thing never forces a full
/// pass.
///
/// The index is a thin loop over [runListOverlay]: pick an entry, run that
/// subpanel (which writes itself), return to the index to hop to another. Esc at
/// the index closes settings. Returns the last subpanel's written [UserConfig]
/// (or null if nothing was written) so the caller can flash a saved/unchanged
/// message.
///
/// Each subpanel [run]s [LineEditor.readKey] like every other modal, so input is
/// serialized the same way; [readEvent] is injectable for tests.
Future<UserConfig?> runSettingsPanel({
  required Screen screen,
  required LineEditor editor,
  required ProviderRegistry registry,
  required Map<String, String> env,
  Directory? tinaDir,
  Future<InputEvent> Function()? readEvent,
}) async {
  UserConfig? lastWritten;
  // The modal is the single blue panel while open: blur the focused conversation
  // panel (so the chat is no longer cyan) and refocus it on close — exactly one
  // blue panel at a time. Sub-panels never touch focus, so the invariant holds for
  // the whole session.
  final grabbed = modalTakeFocus(editor);
  try {
    await _runSettingsSession(screen, editor, registry, env, tinaDir,
        readEvent, (w) => lastWritten = w);
    return lastWritten;
  } finally {
    modalRestoreFocus(editor, grabbed);
  }
}

/// The inner index loop, split out so a single try/finally around it can restore
/// chat focus regardless of how a sub-panel exits.
Future<void> _runSettingsSession(
  Screen screen,
  LineEditor editor,
  ProviderRegistry registry,
  Map<String, String> env,
  Directory? tinaDir,
  Future<InputEvent> Function()? readEvent,
  void Function(UserConfig) onWrote,
) async {
  // Reload from disk before each pick so a subpanel's own write is visible to
  // the next (e.g. enable a provider, then pick a model and see it). The panel
  // always starts from the on-disk config — there is no in-memory seed,
  // mirroring how `/settings` reflects real edits.
  const entries = [
    (display: 'Providers & models', value: 'providers'),
    (display: 'Token quota', value: 'quota'),
    (display: 'Theme', value: 'theme'),
  ];
  while (true) {
    final choice = await runListOverlay<String>(
      screen: screen,
      editor: editor,
      entries: entries,
      title: 'Settings',
      footer: '↑↓ move · enter open · esc close',
      readEvent: readEvent,
      accent: activeAccent(screen),
    );
    if (choice == null) return; // Esc at the index closes settings.

    final initial = loadUserConfig(env: env, tinaDir: tinaDir);
    UserConfig? wrote;
    switch (choice) {
      case 'providers':
        wrote = await runProvidersPanel(
          screen: screen,
          editor: editor,
          registry: registry,
          env: env,
          tinaDir: tinaDir,
          initial: initial,
          readEvent: readEvent,
        );
      case 'quota':
        wrote = await runQuotaPanel(
          screen: screen,
          editor: editor,
          env: env,
          tinaDir: tinaDir,
          initial: initial,
          readEvent: readEvent,
        );
      case 'theme':
        wrote = await runThemePanel(
          screen: screen,
          editor: editor,
          env: env,
          tinaDir: tinaDir,
          initial: initial,
          readEvent: readEvent,
        );
    }
    if (wrote != null) onWrote(wrote);
  }
}

/// Read-modify-write one config slice: load the existing [UserConfig], replace
/// only the supplied slice(s) (threading the untouched fields forward) and
/// [writeUserConfig]. Returns the written config on a real change, or `null`
/// when the supplied slice(s) equal what's already on disk (so the caller can
/// show an "unchanged" message instead of a spurious "saved").
///
/// Each slice arg is null when the panel didn't touch it; comparing the
/// assembled config against the loaded one then isolates the panel's own edit.
///
/// [defaultRef] is a full `"provider/model"` ref for `[default]` (the `/model`
/// picker's "make this the global default"): split on the FIRST slash, since
/// model ids may contain slashes. A value with no slash leaves the slice
/// untouched.
UserConfig? writeUserConfigPatch({
  required Map<String, String> env,
  Directory? tinaDir,
  Map<String, ProviderConfig>? providers,
  LimitsConfig? limits,
  String? themeVariant,
  String? defaultRef,
}) {
  final loaded = loadUserConfig(env: env, tinaDir: tinaDir);

  var nextDefaultProvider = loaded.defaultProvider;
  var nextDefaultModel = loaded.defaultModel;
  if (defaultRef != null) {
    final slash = defaultRef.indexOf('/');
    if (slash > 0) {
      nextDefaultProvider = defaultRef.substring(0, slash);
      nextDefaultModel = defaultRef.substring(slash + 1);
    }
  }

  final nextProviders = providers ?? loaded.providers;
  final nextLimits = limits ?? loaded.limits;
  final nextThemeVariant = themeVariant ?? loaded.themeVariant;

  // Nothing actually changed — skip the write.
  if (_mapsEqual(nextProviders, loaded.providers) &&
      nextLimits == loaded.limits &&
      nextThemeVariant == loaded.themeVariant &&
      nextDefaultProvider == loaded.defaultProvider &&
      nextDefaultModel == loaded.defaultModel) {
    return null;
  }

  // copyWith, not a hand-built literal: the literal used to drop every slice
  // it didn't name (`[default] workflow`, `[regions]`, `[permissions]`, the
  // environment/tui keys) on any write — including this one.
  final built = loaded.copyWith(
    providers: nextProviders,
    limits: nextLimits,
    themeVariant: nextThemeVariant,
    defaultProvider: nextDefaultProvider,
    defaultModel: nextDefaultModel,
  );
  writeUserConfig(built, env: env, tinaDir: tinaDir);
  return built;
}

bool _mapsEqual<K, V>(Map<K, V> a, Map<K, V> b) {
  if (a.length != b.length) return false;
  for (final k in a.keys) {
    if (!b.containsKey(k) || a[k] != b[k]) return false;
  }
  return true;
}

// =============================================================================
// Shared box renderer
// =============================================================================

/// Bordered box (titled top border, body rows, blank + footer), padded/truncated
/// to [rect.height]. Mirrors the box renderer in `setup_overlay.dart`; shared by
/// the subpanels that paint a custom surface (providers, quota). The list-pick
/// subpanels (tiers, theme) delegate to [runListOverlay], which has its own.
///
/// When [accent] is non-null, the frame glyphs and title are colorized with it
/// (the active-focus border color), so the modal reads as the single blue panel.
List<String> _box(
    String title, List<String> body, String footer, Rect rect, Screen screen,
    {String? accent}) {
  String paint(String s) =>
      accent == null ? s : screen.colorize(accent, s);
  final w = rect.width;
  final innerW = w - 4;
  String wrap(String s) {
    final t = s.length > innerW ? s.substring(0, innerW) : s.padRight(innerW);
    return '${paint('│')} $t ${paint('│')}';
  }

  final titleSeg = ' $title ';
  final titleFit =
      titleSeg.length > w - 2 ? titleSeg.substring(0, w - 2) : titleSeg;
  final lines = <String>[
    '${paint('┌')}${paint(titleFit)}${paint('─' * (w - 2 - titleFit.length))}${paint('┐')}',
    ...body.map(wrap),
    wrap(''),
    wrap(footer),
  ];
  while (lines.length < rect.height - 1) {
    lines.add(wrap(''));
  }
  lines.add('${paint('└')}${paint('─' * (w - 2))}${paint('┘')}');
  if (lines.length > rect.height) {
    lines.removeRange(rect.height, lines.length);
  }
  return lines;
}

const _focusMark = '▸';
String _row(bool focused, String text) => '${focused ? _focusMark : ' '} $text';

// =============================================================================
// Subpanel: Providers & models
// =============================================================================

/// A self-contained provider tree. Mirrors the first-run wizard's tree UI but
/// seeds from [initial] and writes only the `[providers]` slice on exit via
/// [writeUserConfigPatch]. Esc cancels without writing.
Future<UserConfig?> runProvidersPanel({
  required Screen screen,
  required LineEditor editor,
  required ProviderRegistry registry,
  required Map<String, String> env,
  Directory? tinaDir,
  required UserConfig initial,
  Future<InputEvent> Function()? readEvent,
}) {
  return _ProvidersForm(screen, registry, env, tinaDir,
      readEvent ?? editor.readKey, initial).run();
}

enum _ProvidersResult { changed, wrote, cancelled }

enum _RowType { provider, key, url, separator, model, addModel, search }

class _Row {
  final _RowType type;
  final int providerIndex;
  final int? modelIndex;
  final bool emptyModels;
  const _Row(this.type, this.providerIndex, this.modelIndex,
      {this.emptyModels = false});
}

class _ProvidersForm {
  _ProvidersForm(
    this._screen,
    this._registry,
    this._env,
    this._tinaDir,
    this._readEvent,
    UserConfig? initial,
  ) : _existingProviders = initial?.providers ?? const {} {
    if (initial != null) {
      _checked.addAll(initial.providers.keys);
      for (final e in initial.providers.entries) {
        final k = e.value.apiKey;
        if (k != null && k.isNotEmpty) _keys[e.key] = k;
        final u = e.value.baseUrl;
        if (u != null && u.isNotEmpty) _baseUrls[e.key] = u;
      }
    }
    // The curation policy lives in ONE place (disabledModelRefsFor) shared
    // with the pickers: every registry provider without an explicitly saved
    // set — including providers with no config block at all — starts with
    // every model disabled.
    _disabledModels.addAll(disabledModelRefsFor(
      initial ?? UserConfig.empty,
      _providerIds,
      (pid) => [for (final m in _registry.modelsFor(pid)) m.id],
    ));
  }

  final Screen _screen;
  final ProviderRegistry _registry;
  final Map<String, String> _env;
  final Directory? _tinaDir;
  final Future<InputEvent> Function() _readEvent;

  final Map<String, ProviderConfig> _existingProviders;

  late final OverlayRegion _overlay;
  late final Rect _rect;

  final _checked = <String>{};
  final _keys = <String, String>{};
  // Provider ids whose empty-field env-var placeholder the user dismissed with
  // Backspace/Delete. The hint is a first-run affordance, not field content:
  // once the user has touched the field it stays gone — including after the
  // key is backspaced away to empty again.
  final _hintDismissed = <String>{};
  final _baseUrls = <String, String>{};
  final _expanded = <String>{};
  final _disabledModels = <String>{};
  // Panel-added custom model specs, keyed by provider id — merged over the
  // registry catalog in the rows and written back into the provider's
  // `models` list on save.
  final _addedModels = <String, List<ProviderModelSpec>>{};
  // Non-null while the ＋add-model row is in text-entry mode: [_addBuf]
  // collects chars until Enter (commit) or Esc (cancel).
  String? _addingFor;
  String _addBuf = '';
  // Provider filter — typing while the /row is focused narrows the list to
  // providers whose id or display name matches (case-insensitive).
  String _searchBuf = '';
  int _focus = 1; // row 0 is the search field; start on the first provider
  int _scrollOffset = 0;
  String? _writeError; // set when a save-time write failed (e.g. read-only)

  List<String> get _providerIds => _registry.providerIds;

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
      if (_addingFor != null) {
        // ＋add-model text entry: Esc cancels the ENTRY (not the panel);
        // Enter commits; ctrlC still tears the panel down.
        if (ev is EscapeKey) {
          _addingFor = null;
          _addBuf = '';
          _render();
          continue;
        }
        if (ev is ControlKey && ev.code == ControlCode.ctrlC) {
          _dispose();
          return null;
        }
        if (ev is ControlKey && ev.code == ControlCode.enter) {
          final spec = ProviderModelSpec.parse(_addBuf);
          final id = _addingFor!;
          if (spec != null) {
            _addedModels
                .putIfAbsent(id, () => [])
                ..removeWhere((s0) => s0.id == spec.id)
                ..add(spec);
            // Declaring a model is an explicit act: enable it immediately,
            // regardless of the provider's curation state.
            _disabledModels.remove('$id/${spec.id}');
            _checked.add(id);
          }
          _addingFor = null;
          _addBuf = '';
          _render();
          continue;
        }
        if (ev is ControlKey && ev.code == ControlCode.backspace) {
          if (_addBuf.isNotEmpty) {
            final runes = _addBuf.runes.toList();
            runes.removeLast();
            _addBuf = String.fromCharCodes(runes);
          }
          _render();
          continue;
        }
        if (ev is CharInput) {
          _addBuf += ev.text;
          _render();
          continue;
        }
        if (ev is PasteInput) {
          _addBuf += ev.text;
          _render();
          continue;
        }
        continue; // arrows etc. are inert while typing the id
      }
      if (ev is EscapeKey ||
          (ev is ControlKey && ev.code == ControlCode.ctrlC)) {
        _dispose();
        return null; // cancel: write nothing
      }
      final result = _dispatch(ev);
      if (result == _ProvidersResult.wrote) {
        // Write before disposing so a read-only config surfaces an error in
        // the modal instead of escaping as an unhandled exception.
        try {
          final cfg = _write();
          _dispose();
          return cfg;
        } on ConfigWriteException catch (e) {
          _writeError = e.toString();
          _render();
          continue;
        }
      }
      switch (result) {
        case _ProvidersResult.changed:
          _render();
        case _ProvidersResult.cancelled:
          _dispose();
          return null;
        case _ProvidersResult.wrote:
          break; // handled above
      }
    }
  }

  void _dispose() {
    _overlay.hide();
    _overlay.dispose();
  }

  _ProvidersResult _dispatch(InputEvent ev) {
    _writeError = null; // any input clears a stale write error
    final rows = _computeRows();
    if (rows.isEmpty) return _ProvidersResult.changed;

    if (ev is ArrowKey) {
      final page = _rect.height - 4;
      switch (ev.direction) {
        case ArrowDirection.up:
        case ArrowDirection.down:
          final d = ev.direction == ArrowDirection.up ? -1 : 1;
          _focus = (_focus + d).clamp(0, rows.length - 1);
          _ensureFocusVisible(rows.length);
          return _ProvidersResult.changed;
        case ArrowDirection.pageUp:
          _focus = (_focus - page).clamp(0, rows.length - 1);
          _ensureFocusVisible(rows.length);
          return _ProvidersResult.changed;
        case ArrowDirection.pageDown:
          _focus = (_focus + page).clamp(0, rows.length - 1);
          _ensureFocusVisible(rows.length);
          return _ProvidersResult.changed;
        case ArrowDirection.right:
          final f = rows[_focus];
          if (f.type == _RowType.provider) {
            _expanded.add(_providerIds[f.providerIndex]);
            _ensureFocusVisible(rows.length);
          }
          return _ProvidersResult.changed;
        case ArrowDirection.left:
          final f = rows[_focus];
          if (f.type == _RowType.provider) {
            _expanded.remove(_providerIds[f.providerIndex]);
          } else {
            _focus = _parentProviderIndex(rows, _focus);
          }
          _ensureFocusVisible(rows.length);
          return _ProvidersResult.changed;
      }
    }

    if (ev is ControlKey && ev.code == ControlCode.backspace) {
      final f = rows[_focus];
      if (f.type == _RowType.search) {
        if (_searchBuf.isNotEmpty) {
          final runes = _searchBuf.runes.toList();
          runes.removeLast();
          _searchBuf = String.fromCharCodes(runes);
        }
        return _ProvidersResult.changed;
      }
      if (f.type == _RowType.key || f.type == _RowType.url) {
        _backspaceField(f);
        return _ProvidersResult.changed;
      }
    }

    // Delete (CSI 3~) has no cursor to act on here — the key/URL fields are
    // append-only, so forward-delete at the end of the text is a no-op. In the
    // API-key field it still clears the env-var placeholder, exactly like
    // Backspace on an already-empty field.
    if (ev is EditingKey && ev.action == EditingAction.delete) {
      final f = rows[_focus];
      if (f.type == _RowType.key) {
        _hintDismissed.add(_providerIds[f.providerIndex]);
        return _ProvidersResult.changed;
      }
    }

    // A paste into a focused key/URL field appends verbatim (the whole point
    // of these rows — pasting an API key). Elsewhere a paste is ignored.
    if (ev is PasteInput) {
      final f = rows[_focus];
      if (f.type == _RowType.key || f.type == _RowType.url) {
        final text = ev.text.trim();
        if (text.isNotEmpty) _appendField(f, text);
        return _ProvidersResult.changed;
      }
    }

    if (ev is CharInput) {
      final c = ev.text;
      final f = rows[_focus];
      if (f.type == _RowType.search) {
        _searchBuf += c;
        return _ProvidersResult.changed;
      }
      if (f.type == _RowType.key || f.type == _RowType.url) {
        _appendField(f, c);
        return _ProvidersResult.changed;
      }
      if (c == ' ') {
        if (f.type == _RowType.provider) {
          _toggle(_providerIds[f.providerIndex]);
          return _ProvidersResult.changed;
        }
        if (f.type == _RowType.model && f.modelIndex != null) {
          _toggleModel(f);
          return _ProvidersResult.changed;
        }
      }
    }

    if (ev is ControlKey && ev.code == ControlCode.enter) {
      final f = rows[_focus];
      if (f.type == _RowType.search) {
        return _ProvidersResult.changed; // not a save trigger
      }
      if (f.type == _RowType.addModel) {
        _addingFor = _providerIds[f.providerIndex];
        _addBuf = '';
        return _ProvidersResult.changed;
      }
      if (_checked.isEmpty) return _ProvidersResult.changed;
      return _ProvidersResult.wrote;
    }
    return _ProvidersResult.changed;
  }

  /// The provider's model entries — the registry catalog plus panel-added
  /// specs (added wins on id conflicts, mirroring the catalog's
  /// declared-replaces-compiled rule).
  List<({String id, String name})> _modelEntries(String pid) {
    final entries = [
      for (final m in _registry.modelsFor(pid)) (id: m.id, name: m.name),
    ];
    for (final spec in (_addedModels[pid] ?? const <ProviderModelSpec>[])) {
      final i = entries.indexWhere((e) => e.id == spec.id);
      final e = (id: spec.id, name: spec.name ?? spec.id);
      if (i >= 0) {
        entries[i] = e;
      } else {
        entries.add(e);
      }
    }
    return entries;
  }

  /// Config-declared models for [id]: the provider's existing declarations
  /// with this session's additions merged in (added wins on id conflicts).
  /// Null when there is nothing to declare, preserving an untouched config.
  List<ProviderModelSpec>? _mergedModels(String id) {
    final added = _addedModels[id];
    if (added == null || added.isEmpty) return _existingProviders[id]?.models;
    final merged = [...?_existingProviders[id]?.models];
    for (final spec in added) {
      merged.removeWhere((s0) => s0.id == spec.id);
      merged.add(spec);
    }
    return merged;
  }

  bool _matchesSearch(String id) {
    final q = _searchBuf.trim().toLowerCase();
    if (q.isEmpty) return true;
    if (id.toLowerCase().contains(q)) return true;
    final name = _registry.descriptor(id)?.name ?? '';
    return name.toLowerCase().contains(q);
  }

  List<_Row> _computeRows() {
    final rows = <_Row>[_Row(_RowType.search, 0, null)];
    for (var pi = 0; pi < _providerIds.length; pi++) {
      if (!_matchesSearch(_providerIds[pi])) continue;
      rows.add(_Row(_RowType.provider, pi, null));
      if (_expanded.contains(_providerIds[pi])) {
        if (_requiresKey(_providerIds[pi])) {
          rows.add(_Row(_RowType.key, pi, null));
          rows.add(_Row(_RowType.url, pi, null));
        }
        rows.add(_Row(_RowType.separator, pi, null));
        final models = _modelEntries(_providerIds[pi]);
        if (models.isEmpty) {
          rows.add(_Row(_RowType.separator, pi, null, emptyModels: true));
        } else {
          for (var mi = 0; mi < models.length; mi++) {
            rows.add(_Row(_RowType.model, pi, mi));
          }
        }
        rows.add(_Row(_RowType.addModel, pi, null));
      }
    }
    return rows;
  }

  void _ensureFocusVisible(int totalRows) {
    if (totalRows == 0) return;
    if (_focus >= totalRows) _focus = totalRows - 1;
    final visibleRows = (_rect.height - 4).clamp(1, totalRows);
    if (_focus < _scrollOffset) {
      _scrollOffset = _focus;
    } else if (_focus >= _scrollOffset + visibleRows) {
      _scrollOffset = _focus - visibleRows + 1;
    }
  }

  void _appendField(_Row f, String c) {
    final id = _providerIds[f.providerIndex];
    // Entering a credential or endpoint IS configuring the provider: select
    // it automatically instead of requiring a separate checkbox toggle.
    _checked.add(id);
    if (f.type == _RowType.key) {
      _keys[id] = (_keys[id] ?? '') + c;
    } else {
      _baseUrls[id] = (_baseUrls[id] ?? '') + c;
    }
  }

  void _backspaceField(_Row f) {
    final id = _providerIds[f.providerIndex];
    if (f.type == _RowType.key) {
      _hintDismissed.add(id);
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

  void _toggle(String id) {
    if (!_checked.add(id)) {
      _checked.remove(id);
      _expanded.remove(id);
      _keys.remove(id);
      _baseUrls.remove(id);
    }
    // Model enablement is independent of the provider checkbox: models stay
    // disabled until each is checked (the 2026-09-09 disable-by-default
    // flip). A configured provider offers nothing until its models are picked.
  }

  void _toggleModel(_Row f) {
    final id = _providerIds[f.providerIndex];
    final models = _modelEntries(id);
    if (f.modelIndex! >= models.length) return;
    final ref = '$id/${models[f.modelIndex!].id}';
    if (!_disabledModels.add(ref)) {
      _disabledModels.remove(ref);
      _checked.add(id);
    }
  }

  /// Hint shown in an empty API-key field: the environment variable that
  /// can supply the credential instead, when the descriptor declares one.
  String _unsetKeyHint(String id) {
    final sources = _registry.descriptor(id)?.authSources;
    if (sources == null || sources.isEmpty) return '';
    return '(or env ${sources.first.envVar})';
  }

  bool _requiresKey(String id) {
    final desc = _registry.descriptor(id);
    return desc != null && !_registry.isAuthOptional(desc);
  }

  UserConfig? _write() {
    final filteredBaseUrls = <String, String>{
      for (final id in _checked)
        if (_baseUrls.containsKey(id)) id: _baseUrls[id]!,
    };
    final dis = <String, Set<String>>{};
    for (final ref in _disabledModels) {
      final slash = ref.indexOf('/');
      if (slash < 0) continue;
      final pid = ref.substring(0, slash);
      final mid = ref.substring(slash + 1);
      dis.putIfAbsent(pid, () => <String>{}).add(mid);
    }
    final providers = <String, ProviderConfig>{
      // Every CHECKED provider is written, key or not: env-credentialed
      // providers carry no stored key, and their model curation must save.
      for (final id in _checked)
        id: ProviderConfig(
          apiKey: _keys[id],
          baseUrl: filteredBaseUrls[id],
          models: _mergedModels(id),
          // Explicit, never null: an empty set is the curated
          // "every model enabled" state, distinct from an absent key (=
          // never curated = all disabled). The config round-trip preserves
          // empty lists for exactly this reason.
          disabledModels: dis[id] ?? const <String>{},
        ),
    };
    return writeUserConfigPatch(
      env: _env,
      tinaDir: _tinaDir,
      providers: providers,
    );
  }

  void _render() => _overlay.show(
      _box('Providers & models', _body(), _footer(), _rect, _screen,
          accent: activeAccent(_screen)));

  List<String> _body() {
    final rows = _computeRows();
    _ensureFocusVisible(rows.length);
    if (rows.isEmpty) return [];

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
          final check = _checked.contains(id) ? '☑' : '☐';
          final arrow = _expanded.contains(id) ? '▼' : '▸';
          final label = _registry.descriptor(id)?.name ?? id;
          lines.add(_row(focused, '$check $arrow $label'));
        case _RowType.key:
          final id = _providerIds[r.providerIndex];
          final k = _keys[id] ?? '';
          final cursor = focused ? '_' : ' ';
          final hint = k.isEmpty && !_hintDismissed.contains(id)
              ? _unsetKeyHint(id)
              : '';
          lines.add(_row(
              focused, '  API key: ${'*' * k.length}$hint$cursor'));
        case _RowType.url:
          final id = _providerIds[r.providerIndex];
          final u = _baseUrls[id] ?? '';
          final cursor = focused ? '_' : ' ';
          // Built-ins ship a compiled defaultBaseUrl; show it so the field
          // reads as optional and the effective value is never a mystery.
          final hint = u.isEmpty
              ? '(default: ${_registry.descriptor(id)?.defaultBaseUrl ?? 'none'})'
              : '';
          lines.add(_row(focused, '  Base URL: $u$hint$cursor'));
        case _RowType.separator:
          if (r.emptyModels) {
            lines.add(_row(false, '  (no known models)'));
          } else {
            lines.add(_row(false, '  ── models ──'));
          }
        case _RowType.search:
          final cursor = focused ? '▏' : '';
          final q = _searchBuf.isEmpty && !focused
              ? '(type to filter providers)'
              : _searchBuf;
          lines.add(_row(focused, '  / $q$cursor'));
        case _RowType.addModel:
          final id = _providerIds[r.providerIndex];
          if (_addingFor == id) {
            lines.add(_row(focused, '  ＋ $_addBuf▏'));
          } else {
            lines.add(_row(focused, '  ＋ add model id (or id|Name)'));
          }
        case _RowType.model:
          final id = _providerIds[r.providerIndex];
          final models = _modelEntries(id);
          if (r.modelIndex! < models.length) {
            final ref = '$id/${models[r.modelIndex!].id}';
            final check = _disabledModels.contains(ref) ? '☐' : '☑';
            lines.add(_row(focused, '  $check ${models[r.modelIndex!].name}'));
          }
      }
    }

    if (hasBelow && lines.isNotEmpty) {
      final nBelow = rows.length - _scrollOffset - slice.length;
      lines[lines.length - 1] = _row(false, '  ↓ $nBelow more');
    }
    if (hasAbove && lines.isNotEmpty) {
      final nAbove = _scrollOffset;
      lines[0] = _row(false, '  ↑ $nAbove more');
    }

    // How fresh the models.dev provider feed is. Absent when discovery is off
    // (`COCOON_MODELS_DEV=0`), in tests, and on headless runs — the registry
    // only carries a catalog when the CLI seeded one.
    final providerCatalog = _registry.providerCatalog;
    if (providerCatalog != null) {
      lines.add(_row(false, '  ${_providerFeedLine(providerCatalog)}'));
    }

    final warning = _registry.catalog?.loadWarning;
    if (warning != null) {
      lines.add(_row(false, ' ⚠ $warning'));
    }
    // The provider feed's failure reason gets its own line: the freshness row
    // is too narrow to carry it without truncating.
    final providerWarning = providerCatalog?.loadWarning;
    if (providerWarning != null) {
      lines.add(_row(false, ' ⚠ $providerWarning'));
    }
    if (_writeError != null) {
      lines.add(_row(false, '⚠ $_writeError'));
    }
    return lines;
  }

  String _footer() =>
      '↑↓ move · → expand · ← collapse · space toggle · enter save · esc cancel';
}

/// One freshness line for the models.dev provider feed: how old the cache this
/// launch seeded from is, and what the background refresh is doing.
///
/// A refresh that lands registers whatever it added into the live registry
/// (see `bin/tina.dart`), so a pending fetch is just "still fetching" — the new
/// providers appear here as soon as it completes, no restart.
String _providerFeedLine(ModelsDevProviderCatalog catalog) {
  final cachedAt = catalog.cachedAt;
  final age = cachedAt == null
      ? 'no cache yet'
      : 'cached ${_ageLabel(DateTime.now().difference(cachedAt))} ago';
  // A failed refresh reports only that it failed here (the reason follows on
  // its own ⚠ line); `refreshPending` is implied by it.
  if (catalog.loadWarning != null) {
    return 'models.dev providers: $age — refresh failed';
  }
  if (catalog.refreshPending) {
    return 'models.dev providers: $age — refreshing';
  }
  return 'models.dev providers: $age — up to date';
}

String _ageLabel(Duration d) {
  if (d.inDays >= 1) return '${d.inDays}d';
  if (d.inHours >= 1) return '${d.inHours}h';
  if (d.inMinutes >= 1) return '${d.inMinutes}m';
  return '${d.inSeconds}s';
}


// =============================================================================
// Subpanel: Token quota
// =============================================================================

/// The six numeric limits from the wizard's limits step, as a self-contained
/// panel that writes only `[limits]`. Editing/digit entry mirrors
/// [_SetupForm._onLimits]; Enter saves, Esc cancels.
Future<UserConfig?> runQuotaPanel({
  required Screen screen,
  required LineEditor editor,
  required Map<String, String> env,
  Directory? tinaDir,
  required UserConfig initial,
  Future<InputEvent> Function()? readEvent,
}) {
  return _QuotaForm(screen, env, tinaDir, readEvent ?? editor.readKey, initial)
      .run();
}

enum _QuotaResult { changed, wrote, cancelled }

class _QuotaForm {
  _QuotaForm(
    this._screen,
    this._env,
    this._tinaDir,
    this._readEvent,
    this._initial,
  ) {
    const ids = [
      'max_session_tokens',
      'max_turn_tokens',
      'max_request_tokens',
      'max_global_tokens',
      'max_sub_agent_tokens',
      'requests_per_minute',
    ];
    const labels = [
      'Session tokens',
      'Turn tokens',
      'Request tokens',
      'Global tokens',
      'Sub-agent tokens',
      'Requests / minute',
    ];
    _limitIds.addAll(ids);
    _limitLabels.addAll(labels);
    final f = _initial.limits ?? const LimitsConfig();
    for (final id in ids) {
      _limitValues[id] = _fieldValue(id, f);
    }
  }

  static int _fieldValue(String id, LimitsConfig f) {
    switch (id) {
      case 'max_session_tokens':
        return f.maxSessionTokens ?? 10000000;
      case 'max_turn_tokens':
        return f.maxTurnTokens ?? 1000000;
      case 'max_request_tokens':
        return f.maxRequestTokens ?? 200000;
      case 'max_global_tokens':
        return f.maxGlobalTokens ?? 50000000;
      case 'max_sub_agent_tokens':
        return f.maxSubAgentTokens ?? 2000000;
      case 'requests_per_minute':
        return f.requestsPerMinute ?? 0;
      default:
        return 0;
    }
  }

  // Snapshot the working values back into a LimitsConfig. Fields this panel
  // doesn't edit (minRequestIntervalMs, maxConcurrentRequests) carry through
  // from the initial config so a save here can't silently drop them.
  LimitsConfig _toConfig() => LimitsConfig(
        maxSessionTokens: _limitValues['max_session_tokens'],
        maxTurnTokens: _limitValues['max_turn_tokens'],
        maxRequestTokens: _limitValues['max_request_tokens'],
        maxGlobalTokens: _limitValues['max_global_tokens'],
        maxSubAgentTokens: _limitValues['max_sub_agent_tokens'],
        requestsPerMinute: _limitValues['requests_per_minute'],
        minRequestIntervalMs:
            (_initial.limits ?? const LimitsConfig()).minRequestIntervalMs,
        maxConcurrentRequests:
            (_initial.limits ?? const LimitsConfig()).maxConcurrentRequests,
      );

  final Screen _screen;
  final Map<String, String> _env;
  final Directory? _tinaDir;
  final Future<InputEvent> Function() _readEvent;

  final UserConfig _initial;
  late final OverlayRegion _overlay;
  late final Rect _rect;

  final _limitIds = <String>[];
  final _limitLabels = <String>[];
  final _limitValues = <String, int>{};
  int _focus = 0;
  String? _writeError; // set when a save-time write failed (e.g. read-only)

  Future<UserConfig?> run() async {
    final layout = _screen.layout;
    final w = (layout.width - 4).clamp(40, 64);
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
      // ignore: avoid_print
      if (ev is EscapeKey ||
          (ev is ControlKey && ev.code == ControlCode.ctrlC)) {
        _dispose();
        return null;
      }
      final result = _dispatch(ev);
      if (result == _QuotaResult.wrote) {
        try {
          final cfg = _write();
          _dispose();
          return cfg;
        } on ConfigWriteException catch (e) {
          _writeError = e.toString();
          _render();
          continue;
        }
      }
      switch (result) {
        case _QuotaResult.changed:
          _render();
        case _QuotaResult.cancelled:
          _dispose();
          return null;
        case _QuotaResult.wrote:
          break; // handled above
      }
    }
  }

  void _dispose() {
    _overlay.hide();
    _overlay.dispose();
  }

  _QuotaResult _dispatch(InputEvent ev) {
    _writeError = null; // any input clears a stale write error
    if (ev is ControlKey && ev.code == ControlCode.enter) {
      return _QuotaResult.wrote;
    }
    if (ev is ControlKey && ev.code == ControlCode.backspace) {
      final id = _limitIds[_focus];
      _limitValues[id] = _limitValues[id]! ~/ 10;
      return _QuotaResult.changed;
    }
    if (ev is ArrowKey) {
      switch (ev.direction) {
        case ArrowDirection.up:
          _focus = (_focus - 1).clamp(0, _limitIds.length - 1);
          return _QuotaResult.changed;
        case ArrowDirection.down:
          _focus = (_focus + 1).clamp(0, _limitIds.length - 1);
          return _QuotaResult.changed;
        case ArrowDirection.pageUp:
        case ArrowDirection.pageDown:
        case ArrowDirection.left:
        case ArrowDirection.right:
          return _QuotaResult.changed;
      }
    }
    if (ev is CharInput && ev.text.length == 1) {
      final c = ev.text.codeUnitAt(0);
      if (c >= 48 && c <= 57) {
        final digit = c - 48;
        final id = _limitIds[_focus];
        final v = _limitValues[id]!;
        if (v == 0) {
          _limitValues[id] = digit;
        } else if ('$v'.length < 12) {
          _limitValues[id] = int.parse('$v$digit');
        }
        return _QuotaResult.changed;
      }
    }
    return _QuotaResult.changed;
  }

  UserConfig? _write() => writeUserConfigPatch(
        env: _env,
        tinaDir: _tinaDir,
        limits: _toConfig(),
      );

  void _render() => _overlay.show(
      _box('Token quota', _body(), _footer(), _rect, _screen,
          accent: activeAccent(_screen)));

  List<String> _body() => [
        'Token limits (enter saves, esc cancels):',
        for (var i = 0; i < _limitIds.length; i++)
          _row(i == _focus, '${_limitLabels[i]}: ${_limitValues[_limitIds[i]]}'),
        if (_writeError != null) _row(false, '⚠ $_writeError'),
      ];

  String _footer() => '↑↓ move · digits edit · backspace del · enter save';
}

// =============================================================================
// Subpanel: Theme
// =============================================================================

/// Dark/light/system theme selection as a self-contained panel that writes only
/// `[theme] variant`. Delegates the list to [runListOverlay]; Enter on an entry
/// saves it immediately and returns to the index.
Future<UserConfig?> runThemePanel({
  required Screen screen,
  required LineEditor editor,
  required Map<String, String> env,
  Directory? tinaDir,
  required UserConfig initial,
  Future<InputEvent> Function()? readEvent,
}) async {
  // value 'system' is represented by a null themeVariant.
  const entries = [
    (display: 'System (default)', value: 'system'),
    (display: 'Dark', value: 'dark'),
    (display: 'Light', value: 'light'),
  ];
  final choice = await runListOverlay<String>(
    screen: screen,
    editor: editor,
    entries: entries,
    title: 'Theme',
    footer: '↑↓ move · enter select · esc cancel',
    readEvent: readEvent,
    accent: activeAccent(screen),
  );
  if (choice == null) return null; // cancelled
  return writeUserConfigPatch(
    env: env,
    tinaDir: tinaDir,
    themeVariant: choice == 'system' ? null : choice,
  );
}
