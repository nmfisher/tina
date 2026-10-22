import 'dart:async';
import 'dart:convert';
import 'package:tina_console/tina_console.dart';
import 'package:tina_settings/tina_settings.dart';
import 'providers_panel.dart';
import 'settings_management.dart';

typedef _SettingsEntry = ({
  String category,
  String label,
  Future<void> Function() open
});

/// Shared scope editor plus specialized provider forms and plugin UI actions.
final class SettingsPanel {
  SettingsPanel(this.screen, this.editor, {this.readEvent});
  final Screen screen;
  final LineEditor editor;
  final Future<InputEvent> Function()? readEvent;
  late Future<InputEvent> Function() _read;
  late OverlayRegion _overlay;
  late ScreenCursor _cursor;
  void Function()? _paint;
  bool _savedSection = false;
  late SettingsManagement _management;
  late SettingsSnapshot _state;
  void repaint() => _paint?.call();
  Completer<void> _changed = Completer<void>();
  Future<InputEvent>? _pendingRead;
  Completer<void> _cancel = Completer<void>();
  bool _cancelled = false;
  SettingScope _scope = SettingScope.session;
  bool _usingScopes = false;
  Set<SettingScope> _availableScopes = {...SettingScope.values};

  /// Whether the Plugins category also lists sections for plugins that are
  /// off in this conversation. Off by default; the category's checkbox row
  /// flips it. Search always finds every setting.
  bool _showOffPlugins = false;
  static const _menuWidth = 80, _menuMaxHeight = 22;
  static const _categories = [
    'General',
    'Models',
    'Appearance',
    'Permissions',
    'Plugins'
  ];
  final _breadcrumbs = <String>[];
  Rect get _frame => dialogBounds(screen.layout,
      preferredWidth: _menuWidth, preferredHeight: _menuMaxHeight);
  int get _contentWidth => (_frame.width - 4).clamp(1, _menuWidth);
  String get _scopeLine => _usingScopes
      ? 'Scope: ${[
          for (final scope
              in SettingScope.values.where(_availableScopes.contains))
            scope == _scope ? '[${scope.name}]' : scope.name
        ].join('  ')}'
      : 'Scope: [global]';
  String _title(String leaf) {
    final full = [..._breadcrumbs, leaf].join(' › ');
    return visibleWidth(full) <= _contentWidth ? full : leaf;
  }

  int get _aboutWidth => (_contentWidth - 2).clamp(1, _menuWidth);
  Future<void> _withinScopes(
      Set<SettingScope> scopes, Future<void> Function() edit) async {
    final previous = _availableScopes;
    _availableScopes = scopes;
    try {
      await edit();
    } finally {
      _availableScopes = previous;
    }
  }

  /// Release a live key reader before its session or frontend is torn down.
  void cancel() {
    _cancelled = true;
    if (!_cancel.isCompleted) _cancel.complete();
  }

  Future<InputEvent?> _nextEvent() async {
    _pendingRead ??= _read();
    final event = await Future.any<InputEvent?>(
        [_pendingRead!, _changed.future.then((_) => null)]);
    if (event != null) {
      _pendingRead = null;
      // Release the losing change listener after each key, rather than
      // accumulating one for every keystroke until a plugin changes.
      final previous = _changed;
      _changed = Completer<void>();
      previous.complete();
    }
    return event;
  }

  void _refresh() {
    _state = _management.settings.snapshot();
    final previous = _changed;
    _changed = Completer<void>();
    previous.complete();
    repaint();
  }

  /// Uses one disposable editor connection; closing the dialog releases that
  /// connection without closing the runtime's shared settings.
  Future<bool> run(
      {required SettingsManagement management,
      SettingsRegistry? sections}) async {
    _management = management;
    _state = management.settings.snapshot(refresh: true);
    _savedSection = false;
    _usingScopes = true;
    _scope = SettingScope.session;
    _availableScopes = {...SettingScope.values};
    _cancelled = false;
    _breadcrumbs.clear();
    _cancel = Completer<void>();
    final input = readEvent == null
        ? editor.openInputSession(cancelSignal: _cancel.future)
        : null;
    _read = readEvent ?? input!.read;
    _pendingRead = null;
    final unlisten = sections?.listen(_refresh);
    final stopSettings = management.listen(_refresh);
    _overlay =
        OverlayRegion(screen, const Rect(row: 0, col: 0, width: 1, height: 1));
    _cursor = screen.claimCursor();
    try {
      return await _scopedRun(sections: sections);
    } finally {
      try {
        unlisten?.call();
        stopSettings.call();
        management.close();
        _paint = null;
        if (!_cancel.isCompleted) _cancel.complete();
        input?.dispose();
        await _pendingRead;
        _pendingRead = null;
        _overlay.hide();
        editor.handleResize();
      } finally {
        _cursor.release();
      }
    }
  }

  Future<void> _manageCommandApprovals() async {
    while (true) {
      final entries = _management.commandApprovals;
      final selected = await _menu('Remembered permissions', [
        for (final entry in entries)
          '${entry['scope']}: ${entry['pattern'] == null ? entry['command'] : 'regex: ${entry['pattern']}'} (${entry['directory']})',
        entries.isEmpty ? 'No remembered approvals — Back' : 'Back',
      ]);
      if (selected == null || selected >= entries.length) return;
      final entry = entries[selected];
      final revoke = await _menu('Revoke ${entry['scope']} approval?', [
        'Revoke: ${entry['pattern'] ?? entry['command']}',
        'Keep approval',
      ]);
      if (revoke == 0) _management.revokeCommandApproval(entry['id'] as String);
    }
  }

  SettingInfo get _defaultModelSetting =>
      _state.catalog['tina/session-controls/default_model'];

  Future<bool> _scopedRun({SettingsRegistry? sections}) async {
    return _browseSettings(() {
      final owners = _state.catalog.definitions
          .map((d) => d.owner)
          .toSet()
          .where((id) =>
              !id.startsWith('tina/providers') &&
              id != 'tina/chat-tui' &&
              id != 'tina/session-controls' &&
              _state.catalog.definitions
                  .any((d) => d.owner == id && !d.id.endsWith('/enabled')))
          .where(_pluginSectionVisible)
          .toList()
        ..sort();
      return [
        if (_management.hasCommandApprovals)
          (
            category: 'Permissions',
            label: 'Remembered permissions',
            open: _manageCommandApprovals,
          ),
        (
          category: 'Models',
          label: 'Default model',
          open: () async {
            if (!await _allowedScope(_defaultModelSetting)) return;
            final draft = _management.openDraft(_scope);
            try {
              await _withinScopes(_defaultModelSetting.scopes,
                  () => _defaultModel(draft, _management.providers));
              if (draft.hasChanges) {
                _management.saveDraft(draft);
                _savedSection = true;
              }
            } finally {
              _management.closeDraft(draft);
            }
          }
        ),
        (
          category: 'Models',
          label: 'Providers and models (Global only)',
          open: () async {
            if (_scope != SettingScope.global) {
              final enter = await _menu('Provider catalog is Global only',
                  ['Edit Global providers', 'Back']);
              if (enter != 0) return;
              _scope = SettingScope.global;
            }
            final draft = _management.openDraft(SettingScope.global,
                providerCatalog: true);
            try {
              await _withinScopes({SettingScope.global},
                  () => _providers(draft, _management.providers));
              if (draft.hasChanges) {
                _management.saveDraft(draft);
                _savedSection = true;
              }
            } finally {
              _management.closeDraft(draft);
            }
          }
        ),
        (
          category: 'Models',
          label: 'Generation settings',
          open: () async {
            final providers = _state.catalog.definitions
                .where((d) => d.id.endsWith('/thinking'))
                .map((d) => d.id.split('/')[2])
                .toList();
            final selected = await _menu('Generation settings', providers);
            if (selected != null) {
              final draft = _management.openDraft(_scope);
              try {
                await _generation(draft, provider: providers[selected]);
              } finally {
                _management.closeDraft(draft);
              }
            }
          }
        ),
        (category: 'Plugins', label: 'Enabled plugins', open: _scopedPlugins),
        (
          category: 'Plugins',
          label:
              '[${_showOffPlugins ? 'x' : ' '}] Show settings for plugins that are off',
          open: () async {
            _showOffPlugins = !_showOffPlugins;
          },
        ),
        (
          category: 'General',
          label: 'Request and token limits',
          open: () => _definitions(
              'Request and token limits',
              () => _state.catalog.definitions
                  .where((d) => d.configPath.first == 'limits')
                  .toList())
        ),
        (
          category: 'Appearance',
          label: 'Theme',
          open: () => _scopedValue(_state.catalog['tina/chat-tui/theme'])
        ),
        (
          category: 'Appearance',
          label: 'Terminal alerts',
          open: () => _definitions('Terminal alerts',
              () => [_state.catalog['tina/chat-tui/terminal_alerts']])
        ),
        for (final owner in owners)
          (
            category: _ownerCategory(owner),
            label: _sectionTitle(owner),
            open: () => _definitions(
                _sectionTitle(owner),
                () => _state.catalog.definitions
                    .where(
                        (d) => d.owner == owner && !d.id.endsWith('/enabled'))
                    .toList())
          ),
        for (final section in sections?.sections ?? <SettingsSection>[])
          (
            category: _ownerCategory(section.id),
            label: section.title,
            open: () async {
              await _section(sections!, section);
              _management.refresh();
              _refresh();
            }
          ),
      ];
    },
        searchEntries: () => [
              for (final definition in _state.catalog.definitions.where((d) =>
                  !d.id.endsWith('/enabled') &&
                  d.id != _defaultModelSetting.id &&
                  d.id != 'tina/chat-tui/theme'))
                (
                  category: _ownerCategory(definition.owner),
                  label:
                      '${definition.label} · ${_sectionTitle(definition.owner)}',
                  open: () => _scopedValue(definition)
                ),
            ],
        attention: () => _state.applicationErrors.values.join('\n'));
  }

  String _ownerCategory(String id) => id.startsWith('tina/providers')
      ? 'Models'
      : switch (id) {
          'tina/mode' ||
          'tina/tools' ||
          'tina/approvals' ||
          'tina/mcp' =>
            'Permissions',
          'tina/step-limit' || 'tina/subagents' || 'tina/goals' => 'General',
          'tina/chat-tui' || 'tina/console' => 'Appearance',
          _ => 'Plugins',
        };

  /// A plugin's settings section appears in the Plugins category only when the
  /// plugin is on in this conversation (or has no enable switch). The
  /// category's "Show settings for plugins that are off" row reveals the rest;
  /// search finds every setting either way.
  bool _pluginSectionVisible(String owner) {
    if (_showOffPlugins) return true;
    SettingInfo? toggle;
    for (final d in _state.catalog.definitions) {
      if (d.id == '$owner/enabled') {
        toggle = d;
        break;
      }
    }
    if (toggle == null) return true; // not a toggleable plugin: always shown
    return _state.read(toggle).value == true;
  }

  Future<bool> _browseSettings(List<_SettingsEntry> Function() entries,
      {List<_SettingsEntry> Function()? searchEntries,
      String Function()? attention}) async {
    var categorySelected = 0;
    while (!_cancelled) {
      var visible = <_SettingsEntry>[];
      var searching = false;
      List<String> items(String query) {
        searching = query.isNotEmpty;
        visible = [...entries(), if (searching) ...?searchEntries?.call()];
        return searching ? visible.map((e) => e.label).toList() : _categories;
      }

      final choice = await _menu('Settings', _categories,
          initialSelected: categorySelected,
          itemsForQuery: items,
          detailFor: (_) => (attention?.call() ?? '').isEmpty
              ? 'Changes save when confirmed · ? help'
              : 'Changes need attention · ? help',
          descriptionFor: (_) =>
              '${attention?.call() ?? ''}\nChoose a category or type to find a setting. '
              'Tab changes scope; Enter confirms edits; Escape cancels the current editor.');
      if (choice == null) return _savedSection;
      if (searching) {
        await _openEntry(visible[choice]);
      } else {
        final category = _categories[choice];
        categorySelected = choice;
        var selectedIndex = 0;
        var query = '';
        _breadcrumbs.add('Settings');
        try {
          while (!_cancelled) {
            visible = entries().where((e) => e.category == category).toList();
            final selected =
                await _menu(category, visible.map((e) => e.label).toList(),
                    initialSelected: selectedIndex,
                    initialQuery: query,
                    onSelected: (value) => selectedIndex = value,
                    onQuery: (value) => query = value,
                    itemsNow: () {
                      visible = entries()
                          .where((e) => e.category == category)
                          .toList();
                      return visible.map((e) => e.label).toList();
                    });
            if (selected == null) break;
            await _openEntry(visible[selected], fromCategory: true);
          }
        } finally {
          _breadcrumbs.removeLast();
        }
      }
    }
    return _savedSection;
  }

  Future<void> _openEntry(_SettingsEntry entry,
      {bool fromCategory = false}) async {
    final count = _breadcrumbs.length;
    _breadcrumbs.addAll([if (!fromCategory) 'Settings', entry.category]);
    try {
      await entry.open();
    } catch (error) {
      await _menu('Could not apply setting', [
        error is FormatException
            ? error.message.toString()
            : error is ArgumentError
                ? error.message.toString()
                : error is SettingsConflict
                    ? error.toString()
                    : error is StateError
                        ? error.message.toString()
                        : 'Check configuration and file permissions.',
        'Back',
      ]);
    } finally {
      _breadcrumbs.removeRange(count, _breadcrumbs.length);
    }
  }

  String _sectionTitle(String id) => switch (id) {
        'tina/step-limit' => 'Step limit',
        'tina/subagents' => 'Subagents',
        'tina/mode' => 'Mode and auto approval',
        'tina/tools' => 'Tools',
        'tina/mcp' => 'MCP servers',
        'tina/approvals' => 'Approvals',
        'tina/goals' => 'Goals',
        _ => id,
      };
  String _settingValue(SettingInfo definition, Object? value) =>
      definition.secret
          ? (value == null || value == '' ? 'unset' : '••••')
          : value == null
              ? 'Inherit'
              : value is int
                  ? formatInteger(value)
                  : value is bool
                      ? (value ? 'On' : 'Off')
                      : value is Map || value is List
                          ? jsonEncode(value)
                          : value.toString();
  String _settingRow(SettingInfo definition) {
    final state = _state.read(definition, scope: _scope);
    return '${definition.label}: ${_settingValue(definition, state.value)}';
  }

  Future<bool> _allowedScope(SettingInfo definition) async {
    if (definition.scopes.contains(_scope)) return true;
    final scopes =
        SettingScope.values.where(definition.scopes.contains).toList();
    final choice = await _menu(
        '${definition.label} · ${definition.scopeReason}',
        [for (final scope in scopes) 'Edit ${scope.name}', 'Back']);
    if (choice == null || choice >= scopes.length) return false;
    _scope = scopes[choice];
    return true;
  }

  Future<void> _definitions(
      String title, List<SettingInfo> Function() definitions) async {
    var selected = 0;
    var query = '';
    while (true) {
      var fields = definitions();
      List<String> items() {
        fields = definitions();
        return fields.map((d) => _settingRow(d)).toList();
      }

      var reset = false;
      final choice = await _menu(title, items(),
          itemsNow: items,
          initialSelected: selected,
          initialQuery: query,
          onSelected: (value) => selected = value,
          onQuery: (value) => query = value,
          canToggle: (i) => fields[i].kind == SettingKind.toggle,
          onReset: () => reset = true,
          detailFor: (i) {
            final field = fields[i];
            final state = _state.read(field, scope: _scope);
            return '${state.source == _scope ? 'Set here' : 'Inherited from ${state.sourceLabel}'} · ${_applyLabel(field.applyAt)} · Ctrl-R inherit';
          },
          descriptionFor: (i) => _definitionHelp(fields[i]));
      if (choice == null) return;
      if (reset) {
        if (await _allowedScope(fields[choice])) {
          _management.settings.update(_scope,
              expectedRevision: _state.revision, remove: {fields[choice].id});
          _refresh();
          _savedSection = true;
        }
      } else {
        await _scopedValue(fields[choice]);
      }
    }
  }

  Future<void> _scopedValue(SettingInfo definition,
      {bool Function()? valid, SettingsClient? client}) async {
    if (!await _allowedScope(definition)) return;
    await _withinScopes(definition.scopes,
        () => _editScopedValue(definition, valid: valid, client: client));
  }

  Future<void> _editScopedValue(SettingInfo definition,
      {bool Function()? valid, SettingsClient? client}) async {
    if (valid?.call() == false) return;
    if (!await _allowedScope(definition)) return;
    final connection = client ?? _management.settings;
    final snapshot = connection.snapshot(refresh: true);
    final scope = _scope;
    final current = snapshot.read(definition, scope: scope).value;
    final Object? value;
    if (definition.kind == SettingKind.toggle) {
      value = current != true;
    } else if (definition.kind == SettingKind.choice) {
      final options = definition.choices;
      final selected = await _menu(definition.label, options,
          valid: valid,
          initialSelected:
              options.indexOf(current.toString()).clamp(0, options.length - 1));
      if (selected == null) return;
      value = options[selected];
    } else {
      final text = await _edit(
          definition.label,
          definition.secret
              ? ''
              : definition.kind == SettingKind.object
                  ? jsonEncode(current)
                  : current.toString(),
          numeric: definition.kind == SettingKind.integer,
          secret: definition.secret,
          valid: valid);
      if (text == null) return;
      value = definition.kind == SettingKind.integer
          ? int.tryParse(text.replaceAll(',', ''))
          : definition.kind == SettingKind.object
              ? jsonDecode(text)
              : text;
    }
    if (valid?.call() == false) return;
    connection.update(scope,
        expectedRevision: snapshot.revision, values: {definition.id: value});
    _refresh();
    _savedSection = true;
  }

  String _definitionHelp(SettingInfo definition) =>
      '${definition.description}\n${[
        for (final scope in SettingScope.values)
          '${scope.name}: ${_settingValue(definition, _state.override(definition, scope))}',
        'Default: ${_settingValue(definition, definition.defaultValue)}',
        'Effective here: ${_settingValue(definition, _state.read(definition).value)} (${_state.read(definition).sourceLabel})',
        'Applies: ${_applyLabel(definition.applyAt)}',
        if (_state.applicationErrors[definition.id] != null)
          _state.applicationErrors[definition.id]!,
      ].join('\n')}';

  String _applyLabel(ApplyAt timing) => switch (timing) {
        ApplyAt.immediately => 'immediately',
        ApplyAt.nextRequest => 'next request',
        ApplyAt.whenIdle => 'when idle',
        ApplyAt.newSession => 'new conversations',
        ApplyAt.restart => 'after restart',
      };
  Future<void> _scopedPlugins() async {
    final fields = _state.catalog.definitions
        .where(
            (d) => d.id.endsWith('/enabled') && d.configPath.first == 'plugins')
        .toList()
      ..sort((a, b) => a.owner.compareTo(b.owner));
    final delivery = _state.catalog['tina/approvals/channel'];
    var pluginInfo = _management.plugins;
    var query = '';
    var selected = 0;
    var column = _scope.index;
    while (true) {
      var reset = false;
      var about = false;
      List<String> items() {
        pluginInfo = _management.plugins;
        return [
          _settingRow(delivery),
          for (final field in fields)
            '[${pluginInfo[field.owner]?.required == true || _state.read(field, scope: _scope).value == true ? 'x' : ' '}] ${field.owner}'
        ];
      }

      final choice = await _menu('Plugins · [-] inherit · [~] mixed', items(),
          itemsNow: items,
          checkboxes: true,
          contextLine: _pluginColumnsHeader,
          onHorizontal: (delta) {
            column = (column + delta) % 4;
            if (column < 3) _scope = SettingScope.values[column];
          },
          rowFor: (i) => i == 0
              ? _settingRow(delivery)
              : _pluginColumnsRow(
                  '${fields[i - 1].owner}${pluginInfo[fields[i - 1].owner]?.required == true ? ' · required' : ''}',
                  [
                    for (final scope in SettingScope.values)
                      _state.override(fields[i - 1], scope) as bool?,
                  ],
                  column),
          showDescription: true,
          initialSelected: selected,
          initialQuery: query,
          onQuery: (value) => query = value,
          onReset: () => reset = true,
          onAbout: () => about = true,
          descriptionFor: (i) => i == 0
              ? delivery.description
              : pluginInfo[fields[i - 1].owner]?.description ??
                  fields[i - 1].description,
          detailFor: (i) => i == 0
              ? 'Selected delivery plugin · opens with conversation'
              : pluginInfo[fields[i - 1].owner]?.required == true
                  ? pluginInfo[fields[i - 1].owner]!.blockingReasons.join('; ')
                  : '${column == 3 ? 'All: toggle session, workspace and global' : '${_scope.name}: ${_state.hasOverride(fields[i - 1], _scope) ? 'set here' : 'inherited from ${_state.read(fields[i - 1], scope: _scope).sourceLabel}'}'} · ${pluginInfo[fields[i - 1].owner]?.status ?? _applyLabel(fields[i - 1].applyAt)}');
      if (choice == null) return;
      selected = choice;
      if (about) {
        final id = choice == 0 ? delivery.owner : fields[choice - 1].owner;
        final blurb = choice == 0
            ? delivery.description
            : pluginInfo[id]?.description ?? fields[choice - 1].description;
        List<String> lines() => wrapDialogWords(blurb, _aboutWidth);
        await _menu('About $id', lines(), itemsNow: lines);
        continue;
      }
      if (choice == 0) {
        await _scopedValue(delivery);
        continue;
      }
      final field = fields[choice - 1];
      final info = pluginInfo[field.owner];
      final required = info?.required == true;
      // A dependency requires the plugin in the effective conversation, not
      // necessarily in every scope. Allow promotion to missing scopes.
      if (required &&
          (reset ||
              (column == 3
                  ? SettingScope.values.every(
                      (scope) => _state.read(field, scope: scope).value == true)
                  : _state.read(field, scope: _scope).value == true))) continue;
      if (reset) {
        if (column == 3) {
          _management.settings.setInAllScopes(field.id, null,
              expectedRevision: _state.revision);
        } else {
          _management.settings.update(_scope,
              expectedRevision: _state.revision, remove: {field.id});
        }
        _refresh();
        _savedSection = true;
        continue;
      }
      // Enabling a plugin with unselected dependencies cascades them on;
      // disabling one with live consumers cascades them off. Both ask once,
      // then commit as one revision-checked write.
      final effective = _state.read(field, scope: _scope).value == true;
      final enabling = required ||
          !effective ||
          (column == 3 &&
              !SettingScope.values
                  .every((scope) => _state.override(field, scope) == true));
      final also = (enabling
              ? info?.missingDependencies ?? const <String>[]
              : info?.dependents ?? const <String>[])
          .where((other) => other != field.owner)
          .toList();
      if (!await _confirmCascade(field.owner, enabling, also)) continue;
      try {
        if (column == 3) {
          // One action across the three layers; dependencies/providers ride
          // along so every intermediate selection stays valid.
          for (final target in [
            if (enabling) ...(info?.missingDependencies ?? const []).reversed,
            field.owner,
            if (!enabling) ...?info?.dependents,
          ]) {
            _management.settings.setInAllScopes(
                '$target/enabled', enabling,
                expectedRevision: _state.revision);
            _refresh();
          }
        } else {
          _management.settings.update(_scope,
              expectedRevision: _state.revision,
              values: {
                field.id: enabling,
                for (final other in also) '$other/enabled': enabling,
              });
        }
        _refresh();
        _savedSection = true;
      } catch (error) {
        await _menu('Could not change plugin', ['$error', 'Back']);
      }
    }
  }

  /// Ask before a toggle cascades to other plugins. Returns true to proceed.
  Future<bool> _confirmCascade(
      String owner, bool enabling, List<String> also) async {
    if (also.isEmpty) return true;
    final lines = [
      if (enabling)
        'Requires enabling:'
      else
        'Also disables:',
      for (final other in also) '  $other',
      'Continue? · Back',
    ];
    final choice = await _menu(
        '${enabling ? 'Enable' : 'Disable'} $owner${also.length > 1 ? ' +${also.length - 1}' : ''}',
        lines,
        initialSelected: lines.length - 1);
    return choice == lines.length - 1;
  }

  Future<void> _generation(ProviderDraft document, {String? provider}) async {
    final form = _management.generation(document, provider: provider);
    if (form.members.isNotEmpty) {
      final choice = await _menu('Generation for pool member', form.members);
      if (choice != null)
        await _generation(document, provider: form.members[choice]);
      return;
    }
    if (!form.exists) {
      await _menu('Choose and save your provider and model first', ['Back']);
      return;
    }
    final id = form.provider;
    final automaticOutput = form.automaticOutput;
    var output = TextLineInput(buffer: form.output, cursor: form.output.length);
    var replaceOutput = true;
    final budget = form.budget;
    final efforts = form.efforts;
    final labels = [
      for (var i = 0; i < efforts.length; i++)
        efforts[i] == 'budget'
            ? 'Custom (${formatInteger(budget!)} tokens)'
            : form.labels[i]
    ];
    var thinking = form.selected;
    var selected = 0;
    String? error;
    _paint = () {
      final prefix = '${selected == 0 ? '›' : ' '} Output limit: ';
      final view = textFieldView(output,
          numeric: true,
          width: (_contentWidth - visibleWidth(prefix)).clamp(1, 10000));
      _show([
        'Generation · $id',
        '$prefix${output.buffer.isEmpty ? 'Automatic (${formatInteger(automaticOutput)})' : view.text}',
        '${selected == 1 ? '›' : ' '} Thinking: ${labels[thinking]}',
        error ??
            '↑↓ select · ←→ edit · Ctrl-U Automatic · Enter save · Esc cancel',
      ],
          cursor: selected == 0
              ? (
                  1,
                  visibleWidth(prefix) +
                      (output.buffer.isEmpty ? 0 : view.cursorColumn)
                )
              : null);
    };
    while (true) {
      repaint();
      final event = await _nextEvent();
      if (event == null) continue;
      error = null;
      switch (event) {
        case EscapeKey():
        case ControlKey(code: ControlCode.ctrlC):
          return;
        case ArrowKey(direction: ArrowDirection.up):
        case ArrowKey(direction: ArrowDirection.down):
        case ControlKey(code: ControlCode.tab):
          selected = 1 - selected;
          replaceOutput = true;
        case ArrowKey(direction: ArrowDirection.left) when selected == 1:
          if (selected == 1) thinking = (thinking - 1) % labels.length;
        case ArrowKey(direction: ArrowDirection.right) when selected == 1:
        case CharInput(text: ' ') when selected == 1:
          if (selected == 1) thinking = (thinking + 1) % labels.length;
        case CharInput(:final text):
        case PasteInput(:final text):
          if (selected == 0) {
            final digits = _numericText(text);
            if (digits == null) {
              error = 'Type a number, or Ctrl-U for Automatic.';
            } else {
              output = (replaceOutput ? const TextLineInput() : output)
                  .insert(digits);
              replaceOutput = false;
            }
          }
        case ControlKey(code: ControlCode.enter):
          final number =
              output.buffer.isEmpty ? null : int.tryParse(output.buffer);
          if (output.buffer.isNotEmpty && (number == null || number <= 0)) {
            error = 'Output limit must be a positive number.';
            continue;
          }
          final fields = <String, dynamic>{
            if (number != null) 'max_output': number,
            if (efforts[thinking] == 'budget')
              'thinking_budget': budget
            else
              'reasoning_effort': efforts[thinking],
          };
          try {
            _management.saveGeneration(document, id, fields);
            _refresh();
            _savedSection = true;
            return;
          } catch (failure) {
            error = failure is SettingsConflict
                ? failure.toString()
                : failure is FormatException
                    ? 'These choices are incompatible. Try Automatic thinking.'
                    : 'Could not save; check permissions or reopen Settings.';
          }
        default:
          if (selected == 0) {
            final edited = _editKey(output, event);
            if (edited != null) {
              output = edited;
              replaceOutput = false;
            }
          }
      }
    }
  }

  Future<void> _section(
      SettingsRegistry registry, SettingsSection section) async {
    while (registry.contains(section)) {
      var controls = <SettingControl>[];
      SettingControl? chosen;
      List<String> items() {
        controls = registry.contains(section) ? section.build() : [];
        if (controls.map((c) => c.id).toSet().length != controls.length) {
          throw StateError('duplicate control ID in ${section.id}');
        }
        return [
          for (final control in controls)
            switch (control) {
              SettingToggle() =>
                '${control.label}: ${control.read() ? 'On' : 'Off'}',
              SettingText() =>
                '${control.label}: ${control.secret ? '••••' : control.read()}',
              SettingChoice() => '${control.label}: ${control.read()}',
              SettingAction() => control.label,
              ScopedSettingControl() =>
                '${control.definition.label}: ${_settingValue(control.definition, control.settings.snapshot().read(control.definition, scope: _scope).value)}',
            }
        ];
      }

      final selected = await _menu(section.title, items(),
          itemsNow: items,
          valid: () => registry.contains(section),
          keysNow: () => controls.map((c) => c.id).toList(),
          canToggle: (i) =>
              controls[i] is SettingToggle ||
              controls[i] is ScopedSettingControl &&
                  (controls[i] as ScopedSettingControl).definition.kind ==
                      SettingKind.toggle,
          onSelected: (index) => chosen = controls[index]);
      if (selected == null || !registry.contains(section)) return;
      final control = chosen!;
      if (_usingScopes &&
          control.scopes != null &&
          !control.scopes!.contains(_scope)) {
        final scopes =
            SettingScope.values.where(control.scopes!.contains).toList();
        final selectedScope = await _menu(
            '${control.label} · choose a supported scope',
            [for (final scope in scopes) 'Edit ${scope.name}', 'Back']);
        if (selectedScope == null || selectedScope >= scopes.length) continue;
        _scope = scopes[selectedScope];
      }
      // Unloading while an editor is open invalidates its callback.
      bool available() =>
          registry.contains(section) &&
          section.build().any((c) => c.id == control.id);
      try {
        await _withinScopes(control.scopes ?? _availableScopes, () async {
          switch (control) {
            case SettingToggle():
              if (available()) await control.change(!control.read());
            case SettingText():
              final value = await _edit(control.label, control.read(),
                  secret: control.secret, valid: available);
              if (value != null && available()) await control.change(value);
            case SettingChoice():
              final index =
                  await _menu(control.label, control.options, valid: available);
              if (index != null && available())
                await control.change(control.options[index]);
            case SettingAction():
              if (available()) await control.invoke();
            case ScopedSettingControl():
              if (available())
                await _scopedValue(control.definition,
                    valid: available, client: control.settings);
          }
        });
      } catch (_) {
        if (registry.contains(section))
          await _menu('Could not apply setting', ['Back'],
              valid: () => registry.contains(section));
      }
    }
  }

  Future<InputEvent> _formEvent() async {
    while (!_cancelled) {
      final event = await _nextEvent();
      if (event != null) return event;
    }
    return EscapeKey();
  }

  Future<bool> _defaultModel(
      ProviderDraft document, List<ProviderOption> descriptors) async {
    final providers = document.table('providers');
    final defaults = document.table('default');
    final currentId = defaults['provider'] as String? ?? 'anthropic';
    final ids = providers.isEmpty
        ? {...descriptors.map((d) => d.id), currentId}.toList()
        : {...providers.keys, currentId}.toList();
    final refs = <String>[];
    final names = <String, String>{};
    final modelNames = <String, String>{};
    for (final id in ids) {
      final descriptor = descriptors.where((d) => d.id == id).firstOrNull;
      final values = providers[id];
      final fields =
          (values as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{};
      final disabled =
          (fields['disabled_models'] as List? ?? const []).cast<String>();
      names[id] = fields['name'] as String? ?? descriptor?.name ?? id;
      final models = providerModels(descriptor, fields);
      for (final model in models.entries) {
        if (disabled.contains(model.key)) continue;
        refs.add('$id/${model.key}');
        modelNames['$id/${model.key}'] = model.value;
      }
      final current = defaults['model'] as String? ?? '';
      if (id == currentId &&
          current.isNotEmpty &&
          !disabled.contains(current) &&
          !refs.contains('$id/$current')) refs.add('$id/$current');
    }
    final picker = ModelSearchPicker(
        screen: screen,
        modelRefs: refs,
        providerNames: names,
        modelNames: modelNames,
        title: _title('Choose default model'),
        bounds: () => _frame,
        contextLine: () => _scopeLine,
        readEvent: _formEvent,
        accent: screen.theme.border.focus);
    _overlay.hide();
    _paint = picker.repaint;
    try {
      final chosen = await picker.run();
      if (chosen != null) {
        final slash = chosen.indexOf('/');
        defaults['provider'] = chosen.substring(0, slash);
        defaults['model'] = chosen.substring(slash + 1);
      }
      return chosen != null;
    } finally {
      _paint = null;
    }
  }

  Future<bool> _providers(
      ProviderDraft document, List<ProviderOption> descriptors) async {
    final draft = document.fork();
    late final ProvidersPanel panel;
    panel = ProvidersPanel(
        screen: screen,
        readEvent: _formEvent,
        draft: draft,
        descriptors: descriptors,
        bounds: () => _frame,
        contextLine: () => _scopeLine,
        title: _title('Providers & models'),
        editAdvanced: (id) => _providerFields(draft, descriptors, id,
            generationDocument: document),
        onShow: () => _paint = panel.repaint);
    _overlay.hide();
    try {
      if (await panel.run()) {
        final defaults = draft.table('default');
        final id = defaults['provider'] as String? ?? 'anthropic';
        final values = draft.table('providers')[id];
        if (values is Map<String, dynamic> &&
            (values['disabled_models'] as List? ?? const [])
                .contains(defaults['model'])) {
          final previous = defaults['model'];
          await _defaultModel(draft, descriptors);
          if (defaults['model'] == previous) return false;
        }
        document.values['providers'] = draft.table('providers');
        document.values['default'] = draft.table('default');
        document.secretEdits.addAll(draft.secretEdits);
        return true;
      }
      return false;
    } finally {
      _paint = null;
    }
  }

  Future<void> _providerFields(
      ProviderDraft document, List<ProviderOption> descriptors, String id,
      {ProviderDraft? generationDocument}) async {
    final providers = document.table('providers');
    final ids = {...descriptors.map((d) => d.id), ...providers.keys}.toList();
    final values = providers.putIfAbsent(id, () => <String, dynamic>{})
        as Map<String, dynamic>;
    final builtin = descriptors.where((d) => d.id == id).firstOrNull;
    while (true) {
      const fields = [
        'name',
        'wire',
        'base_url',
        'api_key',
        'auth_token',
        'models',
        'disabled_models',
        'members',
        'requests_per_minute',
        'min_request_interval_ms',
        'generation',
        'output_token_field'
      ];
      const labels = [
        'Display name',
        'Wire',
        'Base URL',
        'API key',
        'Auth token',
        'Models (id|label)',
        'Disabled models',
        'Pool members (provider or provider/model)',
        'Requests per minute',
        'Request spacing (ms)',
        'Generation settings',
        'Output token field'
      ];
      final choice = await _menu('Provider: $id', [
        for (var i = 0; i < fields.length; i++)
          fields[i] == 'generation'
              ? labels[i]
              : '${labels[i]}: ${_preview(fields[i], document.hasSecret(id, fields[i]) ? true : values[fields[i]])}',
        'Back',
      ]);
      if (choice == null || choice == fields.length) break;
      final field = fields[choice];
      if (field == 'generation') {
        final target = generationDocument ?? document;
        await _generation(target, provider: id);
        if (!identical(target, document)) {
          document.revision = target.revision;
          // Generation saves immediately; keep its saved values when the
          // provider tree later applies its independent credential/model draft.
          for (final entry in target.table('providers').entries) {
            final draft = providers[entry.key];
            if (draft is! Map<String, dynamic> || entry.value is! Map) continue;
            final saved = entry.value as Map;
            for (final key in [
              'max_output',
              'reasoning_effort',
              'thinking_budget'
            ]) {
              if (saved.containsKey(key))
                draft[key] = saved[key];
              else
                draft.remove(key);
            }
          }
        }
      } else if (field == 'api_key' || field == 'auth_token') {
        final previous = document.secret(id, field);
        final value =
            await _edit(labels[choice], previous.value ?? '', secret: true);
        if (value != null)
          document.editSecret(
              id,
              field,
              value.isEmpty
                  ? const SecretEdit.clear()
                  : SecretEdit.replace(value));
      } else if (field == 'wire') {
        final wires = ['Provider default', 'openai', 'anthropic', 'gemini'];
        final wire = await _menu('Wire protocol', wires);
        if (wire != null) {
          if (wire == 0) {
            values.remove('wire');
          } else {
            values['wire'] = wires[wire];
            // An explicit wire requires an explicit endpoint, even when unchanged.
            if (builtin != null && !values.containsKey('base_url'))
              values['base_url'] = builtin.baseUrl;
          }
        }
      } else {
        await _field(values, field, labels[choice],
            secret: field == 'api_key' || field == 'auth_token',
            list: ['models', 'disabled_models', 'members'].contains(field),
            numeric: ['requests_per_minute', 'min_request_interval_ms']
                .contains(field),
            suggestions: field == 'members'
                ? ids
                : field == 'output_token_field'
                    ? ['max_tokens', 'max_completion_tokens']
                    : ['models', 'disabled_models'].contains(field)
                        ? (builtin?.models.keys.toList() ?? [])
                        : const []);
      }
    }
  }

  String _preview(String field, Object? value) {
    if (value == null) return 'default';
    if (field == 'api_key' || field == 'auth_token') return 'configured';
    return value is List
        ? value.join(', ')
        : value is int
            ? formatInteger(value)
            : value.toString();
  }

  List<String> _list(String text) =>
      text.split(',').map((v) => v.trim()).where((v) => v.isNotEmpty).toList();

  Future<bool> _field(Map<String, dynamic> values, String key, String label,
      {bool secret = false,
      bool list = false,
      bool numeric = false,
      List<String> suggestions = const []}) async {
    final old = values[key];
    final value = await _edit(
        label, old is List ? old.join(', ') : old?.toString() ?? '',
        secret: secret, numeric: numeric, suggestions: suggestions);
    if (value == null) return false;
    if (numeric && value.isNotEmpty) {
      final number = int.tryParse(value);
      if (number == null || number < 0) {
        await _menu('Enter a nonnegative integer', ['Back']);
        return false;
      }
      values[key] = number;
    } else if (list) {
      values[key] = _list(value);
    } else if (value.isEmpty) {
      values.remove(key);
    } else {
      values[key] = value;
    }
    return true;
  }

  void _show(List<String> lines, {(int, int)? cursor, String? contextLine}) {
    final target = _frame;
    if (lines.isEmpty) return;
    final boxed = target.width >= 4 && target.height >= 4;
    final scopeRows = boxed && target.height >= 6 ? 1 : 0;
    final title = _title(lines.first);
    final body = [
      if (scopeRows > 0) contextLine ?? _scopeLine,
      ...lines.skip(1).take((lines.length - 2).clamp(0, lines.length))
    ];
    final visible = boxed
        ? dialogBoxLines(
            width: target.width,
            height: target.height,
            title: title,
            body: body,
            footer: lines.length > 1 ? lines.last : '',
            paint: (text) => screen.colorize(screen.theme.border.focus, text))
        : [title, ...body, if (lines.length > 1) lines.last]
            .take(target.height)
            .map((v) => clipDialogText(v, target.width))
            .toList();
    screen.frame(() {
      _overlay.update(bounds: target, lines: visible);
      if (cursor != null && target.height > 0 && target.width > 0) {
        _cursor.place(
            target.row + (cursor.$1 + scopeRows).clamp(0, target.height - 1),
            target.col +
                (cursor.$2 + (boxed ? 2 : 0)).clamp(0, target.width - 1));
      } else {
        _cursor.hide();
      }
    });
  }

  String _compactRow(String row) {
    final split = row.indexOf(': ');
    if (split <= 0 || row.startsWith('Scope:')) return row;
    final name = row.substring(0, split);
    final value = row.substring(split + 2);
    final column = (_contentWidth ~/ 2).clamp(12, 32);
    if (_contentWidth < 32 || visibleWidth(name) >= column) return row;
    return '$name${' ' * (column - visibleWidth(name))}$value';
  }

  int get _pluginCellWidth => _contentWidth >= 60 ? 10 : 5;
  int get _pluginNameWidth =>
      (_contentWidth - 2 - 4 * _pluginCellWidth).clamp(1, _menuWidth);
  String _pluginCell(String text) =>
      clipDialogText(text, _pluginCellWidth).padRight(_pluginCellWidth);
  String _pluginName(String name) =>
      clipDialogText(name, _pluginNameWidth).padRight(_pluginNameWidth);
  String _pluginColumnsHeader() => '  ${_pluginName('Plugin')}${[
        for (final name in _contentWidth >= 60
            ? ['Session', 'Workspace', 'Global', 'All']
            : ['Sess', 'Work', 'Glob', 'All'])
          _pluginCell(name),
      ].join()}';
  String _pluginColumnsRow(String id, List<bool?> values, int column) {
    final all = values.every((v) => v == true)
        ? 'x'
        : values.every((v) => v == false)
            ? ' '
            : values.every((v) => v == null)
                ? '-'
                : '~';
    return '${_pluginName(id)}${[
      for (var i = 0; i < 4; i++)
        _pluginCell(
            '${column == i ? '>' : ' '}[${i == 3 ? all : values[i] == null ? '-' : values[i] == true ? 'x' : ' '}]'),
    ].join()}';
  }

  Future<int?> _menu(String title, List<String> items,
      {int initialSelected = 0,
      String initialQuery = '',
      void Function(String)? onQuery,
      bool checkboxes = false,
      String Function()? contextLine,
      String Function(int)? rowFor,
      void Function(int)? onHorizontal,
      String Function(int)? detailFor,
      String Function(int)? descriptionFor,
      bool showDescription = false,
      void Function()? onAbout,
      void Function()? onReset,
      List<String> Function()? itemsNow,
      List<String> Function(String)? itemsForQuery,
      bool Function(int)? canToggle,
      List<String> Function()? keysNow,
      void Function(int)? onSelected,
      bool Function()? valid}) async {
    var selected = initialSelected;
    var query = initialQuery;
    String? selectedKey = initialSelected < items.length
        ? (keysNow?.call() ?? items)[initialSelected]
        : null;
    List<int> matches() => [
          for (var i = 0; i < items.length; i++)
            if (items[i].toLowerCase().contains(query.toLowerCase())) i
        ];
    _paint = () {
      items = itemsNow?.call() ?? items;
      items = itemsForQuery?.call(query) ?? items;
      final filtered = matches();
      final bounds = _frame;
      final bodyHeight = (bounds.height -
              (bounds.height >= 4 ? 4 : 2) -
              (bounds.height >= 6 ? 1 : 0))
          .clamp(1, _menuMaxHeight);
      final titleRows = 1;
      final footerRows = 1;
      final searchRows = bodyHeight >= 2 ? 1 : 0;
      // Reserve a stable description area in plugin selectors. On short
      // screens it takes precedence over status, with at least one item left
      // visible. The full text remains available through ?.
      final inlineDescription = showDescription && descriptionFor != null;
      final detailRows =
          bodyHeight >= 3 && (!inlineDescription || bodyHeight >= 5) ? 1 : 0;
      final descriptionRows = inlineDescription
          ? (bodyHeight - searchRows - detailRows - 1).clamp(0, 3)
          : 0;
      final room = (bodyHeight - searchRows - detailRows - descriptionRows)
          .clamp(1, _menuMaxHeight);
      final footer = onHorizontal != null
          ? '←→/Tab column · space toggle · ^R inherit · ? about · esc'
          : checkboxes
              ? '${_usingScopes ? 'Tab scope · ' : ''}space toggle · ^R inherit · ? about · esc'
              : '${_usingScopes ? 'Tab scope · ' : ''}↑↓ move · ${canToggle != null ? 'space toggle · ' : ''}enter select · esc back${descriptionFor != null ? ' · ? help' : ''}';
      if (filtered.isEmpty) {
        _show([
          if (titleRows > 0)
            contextLine != null && bounds.height < 6 ? contextLine() : title,
          if (searchRows > 0) 'Find: $query',
          if (room > 0) 'No matches · backspace to edit',
          for (var i = 1; i < room; i++) '',
          for (var i = 0; i < detailRows; i++) '',
          for (var i = 0; i < descriptionRows; i++) '',
          if (footerRows > 0) footer,
        ], contextLine: contextLine?.call());
        return;
      }
      selected = selected.clamp(0, filtered.length - 1);
      final keys = keysNow?.call() ?? items;
      if (selectedKey != null) {
        final previous = filtered.indexWhere((i) => keys[i] == selectedKey);
        if (previous >= 0) selected = previous;
      }
      selectedKey = keys[filtered[selected]];
      final shownRows = room.clamp(0, filtered.length);
      final start =
          (selected - shownRows + 1).clamp(0, filtered.length - shownRows);
      final description = descriptionRows == 0
          ? const <String>[]
          : wrapDialogWords(descriptionFor!(filtered[selected]), _contentWidth);
      _show([
        if (titleRows > 0)
          contextLine != null && bounds.height < 6 ? contextLine() : title,
        if (searchRows > 0) 'Find: $query',
        for (var i = start; i < start + shownRows; i++)
          '${selected == i ? '›' : ' '} ${rowFor?.call(filtered[i]) ?? _compactRow(items[filtered[i]])}',
        for (var i = shownRows; i < room; i++) '',
        if (detailRows > 0) detailFor?.call(filtered[selected]) ?? '',
        for (var i = 0; i < descriptionRows; i++)
          if (i < description.length)
            i == descriptionRows - 1 && description.length > descriptionRows
                ? '${clipDialogText(description[i], (_contentWidth - 1).clamp(0, _contentWidth))}…'
                : description[i]
          else
            '',
        if (footerRows > 0)
          inlineDescription && descriptionRows == 0
              ? clipDialogText(
                  descriptionFor(filtered[selected]), _contentWidth)
              : footer,
      ], contextLine: contextLine?.call());
    };
    while (true) {
      if (_cancelled) return null;
      if (valid?.call() == false) return null;
      repaint();
      final event = await _nextEvent();
      if (valid?.call() == false) return null;
      if (event == null) continue;
      repaint();
      final filtered = matches();
      switch (event) {
        case ControlKey(code: ControlCode.tab) when onHorizontal != null:
          onHorizontal(1);
        case ArrowKey(direction: ArrowDirection.left) when onHorizontal != null:
          onHorizontal(-1);
        case ArrowKey(direction: ArrowDirection.right)
            when onHorizontal != null:
          onHorizontal(1);
        case ControlKey(code: ControlCode.tab) when _usingScopes:
          final scopes =
              SettingScope.values.where(_availableScopes.contains).toList();
          _scope = scopes[(scopes.indexOf(_scope) + 1) % scopes.length];
        case EscapeKey():
          return null;
        case ControlKey(code: ControlCode.ctrlC):
          return null;
        case ControlKey(code: ControlCode.enter):
          if (filtered.isNotEmpty) {
            onQuery?.call(query);
            onSelected?.call(filtered[selected]);
            return filtered[selected];
          }
        case CharInput(text: '?') when onAbout != null:
          if (filtered.isNotEmpty) {
            onAbout();
            onQuery?.call(query);
            return filtered[selected];
          }
        case CharInput(text: '?') when descriptionFor != null:
          if (filtered.isNotEmpty) {
            final paint = _paint;
            try {
              await _menu(
                  'About $title',
                  wrapDialogWords(
                      descriptionFor(filtered[selected]), _aboutWidth));
            } finally {
              _paint = paint;
            }
          }
        case CharInput(text: ' ')
            when checkboxes ||
                filtered.isNotEmpty &&
                    canToggle?.call(filtered[selected]) == true:
          if (filtered.isNotEmpty) {
            onQuery?.call(query);
            onSelected?.call(filtered[selected]);
            return filtered[selected];
          }
        case ControlKey(code: ControlCode.ctrlR) when onReset != null:
        case ControlKey(code: ControlCode.backspace)
            when checkboxes && query.isEmpty:
          if (filtered.isNotEmpty) {
            onReset?.call();
            onQuery?.call(query);
            onSelected?.call(filtered[selected]);
            return filtered[selected];
          }
        case CharInput(:final text):
        case PasteInput(:final text):
          query += text.replaceAll(RegExp(r'[\r\n]'), '');
          selected = 0;
          selectedKey = null;
        case ControlKey(code: ControlCode.backspace):
          if (query.isNotEmpty) query = query.substring(0, query.length - 1);
          selected = 0;
          selectedKey = null;
        case ArrowKey(direction: ArrowDirection.up):
          selected = (selected - 1)
              .clamp(0, filtered.isEmpty ? 0 : filtered.length - 1);
          selectedKey = null;
        case ArrowKey(direction: ArrowDirection.down):
          selected = (selected + 1)
              .clamp(0, filtered.isEmpty ? 0 : filtered.length - 1);
          selectedKey = null;
        case ArrowKey(direction: ArrowDirection.pageUp):
        case ArrowKey(direction: ArrowDirection.pageDown):
          final page = (_frame.height - 7).clamp(1, _menuMaxHeight);
          final direction = event.direction;
          selected =
              (selected + (direction == ArrowDirection.pageUp ? -page : page))
                  .clamp(0, filtered.isEmpty ? 0 : filtered.length - 1);
          selectedKey = null;
        case ScrollEvent(:final up):
          selected = (selected + (up ? -1 : 1))
              .clamp(0, filtered.isEmpty ? 0 : filtered.length - 1);
          selectedKey = null;
        default:
          break;
      }
    }
  }

  Future<String?> _edit(String label, String initial,
      {bool secret = false,
      bool numeric = false,
      List<String> suggestions = const [],
      bool Function()? valid}) async {
    var input = TextLineInput(buffer: initial, cursor: initial.length);
    String? error;
    _paint = () {
      final view = textFieldView(input,
          width: _contentWidth, secret: secret, numeric: numeric);
      _show([
        label,
        view.text,
        error ??
            '${suggestions.isEmpty ? '' : 'tab complete · '}enter accept · esc cancel · ctrl-u clear'
      ], cursor: (
        1,
        view.cursorColumn
      ));
    };
    while (true) {
      if (valid?.call() == false) return null;
      repaint();
      final event = await _nextEvent();
      if (valid?.call() == false) return null;
      if (event == null) continue;
      error = null;
      switch (event) {
        case EscapeKey():
          return null;
        case ControlKey(code: ControlCode.ctrlC):
          return null;
        case ControlKey(code: ControlCode.enter):
          return input.buffer;
        case ControlKey(code: ControlCode.tab):
          if (!secret) {
            final before = input.buffer.substring(0, input.cursor);
            final start = before.lastIndexOf(',') + 1;
            final prefix = before.substring(start).trimLeft();
            final options =
                suggestions.where((v) => v.startsWith(prefix)).toList();
            if (options.isNotEmpty) {
              final replacement =
                  '${before.substring(0, start)}${start > 0 ? ' ' : ''}${options.first}';
              input = TextLineInput(
                  buffer: replacement + input.buffer.substring(input.cursor),
                  cursor: replacement.length);
            }
          }
        case CharInput(:final text):
        case PasteInput(:final text):
          final value = numeric
              ? _numericText(text)
              : text.replaceAll(RegExp(r'[\r\n]'), '');
          if (value == null) {
            error = 'Enter a nonnegative integer (commas are allowed).';
          } else {
            input = input.insert(value);
          }
        default:
          input = _editKey(input, event) ?? input;
      }
    }
  }

  String? _numericText(String text) {
    text = text.trim();
    return RegExp(r'^(?:\d+|\d{1,3}(?:,\d{3})+)$').hasMatch(text)
        ? text.replaceAll(',', '')
        : null;
  }

  TextLineInput? _editKey(TextLineInput input, InputEvent event) =>
      switch (event) {
        ControlKey(code: ControlCode.backspace) => input.backspace(),
        ArrowKey(
          direction: ArrowDirection.left,
          :final hasAlt,
          :final hasCtrl
        ) =>
          hasAlt || hasCtrl ? input.moveWordLeft() : input.moveLeft(),
        ArrowKey(
          direction: ArrowDirection.right,
          :final hasAlt,
          :final hasCtrl
        ) =>
          hasAlt || hasCtrl ? input.moveWordRight() : input.moveRight(),
        EditingKey(action: EditingAction.home) => input.moveHome(),
        EditingKey(action: EditingAction.end) => input.moveEnd(),
        EditingKey(action: EditingAction.delete) => input.deleteForward(),
        EditingKey(action: EditingAction.killToStart) => const TextLineInput(),
        EditingKey(action: EditingAction.killToEnd) => input.killToEnd(),
        EditingKey(action: EditingAction.deleteWordBackward) =>
          input.killWordBackward(),
        EditingKey(action: EditingAction.deleteWordForward) =>
          input.killWordForward(),
        _ => null,
      };
}
