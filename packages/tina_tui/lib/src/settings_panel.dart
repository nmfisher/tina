import 'dart:async';
import 'package:tina_console/tina_console.dart';
import 'package:tina_llm/tina_llm.dart';
import 'assembly_config.dart';
import 'config_document.dart';
import 'configured_provider.dart';
import 'providers_panel.dart';
import 'plugin_settings.dart';
import 'package:tina_host/tina_host.dart';

/// Built-in fields edit global settings; generation can apply live. Plugin sections
/// supply their own controls and callbacks independently of that document.
final class SettingsPanel {
  SettingsPanel(this.screen, this.editor, {this.readEvent});
  final Screen screen;
  final LineEditor editor;
  final Future<InputEvent> Function()? readEvent;
  late Future<InputEvent> Function() _read;
  late OverlayRegion _overlay;
  void Function()? _paint;
  bool _savedSection = false;
  void Function()? _applyGeneration;
  void repaint() => _paint?.call();
  Completer<void> _changed = Completer<void>();
  Future<InputEvent>? _pendingRead;
  Completer<void> _cancel = Completer<void>();
  bool _cancelled = false;

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
    final previous = _changed;
    _changed = Completer<void>();
    previous.complete();
    repaint();
  }

  Future<bool> run(
      {required String path,
      List<ProviderDescriptor>? descriptors,
      void Function(Iterable<String>)? validatePlugins,
      SettingsRegistry? sections,
      PluginSettings<dynamic>? pluginSettings,
      PluginManager<dynamic>? pluginManager,
      void Function()? applyGeneration,
      Map<String, String> pluginDescriptions = const {},
      Iterable<String> pluginIds = const []}) async {
    _savedSection = false;
    _cancelled = false;
    _cancel = Completer<void>();
    _applyGeneration = applyGeneration;
    descriptors ??= configuredDescriptors();
    final document = ConfigDocument.open(path);
    if (!document.existsOnDisk &&
        document.table('default')['model'] == kTinaDefaultModel) {
      document.table('default')['model'] = '';
    }
    _read = readEvent ??
        editor.captureKeyReader(
            acceptPaste: true, cancelSignal: _cancel.future);
    _pendingRead = null;
    final unlisten = sections?.listen(_refresh);
    _overlay =
        OverlayRegion(screen, const Rect(row: 0, col: 0, width: 1, height: 1));
    try {
      while (true) {
        if (_cancelled) return _savedSection;
        final defaults = document.table('default');
        SettingsSection? chosenSection;
        var currentSections = <SettingsSection>[];
        List<String> items() {
          currentSections = sections?.sections ?? [];
          return [
            'Default provider: ${defaults['provider'] ?? 'anthropic'}',
            'Default model: ${defaults['model'] ?? ''}',
            'Providers and models',
            'Plugins',
            'Save changes',
            'Request and token limits',
            'Generation settings',
            'Theme',
            for (final section in currentSections)
              '${section.title} (${section.id})',
          ];
        }

        var selected = await _menu(
            document.hasChanges
                ? 'Settings · unsaved changes'
                : _savedSection
                    ? 'Settings · saved'
                    : 'Settings',
            items(),
            itemsNow: items, onSelected: (index) {
          if (index >= 8) chosenSection = currentSections[index - 8];
        });
        if (_cancelled) return _savedSection;
        if (selected == null) {
          if (!document.hasChanges) return _savedSection;
          final exit = await _menu('Unsaved settings', [
            'Save changes and close',
            'Discard changes',
            'Keep editing',
          ]);
          if (exit == 1) return _savedSection;
          if (exit != 0) continue;
          selected = 4;
        }
        if (chosenSection != null) {
          await _section(sections!, chosenSection!);
          document.refreshUneditedTables();
          continue;
        }
        switch (selected) {
          case 0:
          case 1:
            await _defaultModel(document, descriptors);
          case 2:
            await _providers(document, descriptors, validatePlugins);
          case 3:
            await _plugins(document, pluginIds.toList(), pluginSettings,
                pluginManager, pluginDescriptions);
          case 4:
            try {
              document.save(
                  descriptors: descriptors, validatePlugins: validatePlugins);
              _applyGeneration?.call();
              return true;
            } catch (error) {
              // Parsing errors contain field names, never credential values.
              await _menu('Could not save', [
                error is FormatException
                    ? error.message.toString()
                    : error is ArgumentError
                        ? error.message.toString()
                        : 'Config could not be saved; check file permissions or external edits.',
                'Back'
              ]);
            }
          case 5:
            final values = document.table('limits');
            const fields = {
              'max_global_tokens': 'Global token limit',
              'max_session_tokens': 'Session token limit',
              'max_turn_tokens': 'Turn token limit',
              'max_request_tokens': 'Request token limit',
              'max_sub_agent_tokens': 'Sub-agent token limit',
              'max_sub_agent_depth': 'Sub-agent depth',
              'max_sub_agent_concurrency': 'Concurrent sub-agents',
              'requests_per_minute': 'Requests per minute',
              'min_request_interval_ms': 'Minimum request interval (ms)',
              'max_concurrent_requests': 'Concurrent requests'
            };
            final keys = fields.keys.toList();
            final index = await _menu('Limits (0 disables token/rate caps)', [
              for (final key in keys)
                '${fields[key]}: ${_preview(key, values[key])}'
            ]);
            if (index != null)
              await _field(values, keys[index], fields[keys[index]]!,
                  numeric: true);
          case 6:
            await _generation(document, descriptors, validatePlugins);
          case 7:
            final variants = ['default', 'light', 'dark'];
            final index =
                await _menu('Theme variant (keeps custom colors)', variants);
            if (index != null)
              document.table('theme')['variant'] = variants[index];
        }
      }
    } finally {
      unlisten?.call();
      _paint = null;
      if (!_cancel.isCompleted) _cancel.complete();
      await _pendingRead;
      _pendingRead = null;
      _overlay.hide();
      editor.endKeyCaptureWindow();
      editor.handleResize();
    }
  }

  Future<void> _generation(
      ConfigDocument document,
      List<ProviderDescriptor> descriptors,
      void Function(Iterable<String>)? validatePlugins,
      {String? provider}) async {
    final parsed = parseTinaConfig(document.values, descriptors: descriptors);
    final config = parsed.config;
    final id = provider ?? config.providerId ?? 'anthropic';
    final settings = config.providers[id];
    if (settings?.members.isNotEmpty == true) {
      final members =
          settings!.members.map((m) => m.split('/').first).toSet().toList();
      final choice = await _menu('Generation for pool member', members);
      if (choice != null) {
        await _generation(document, descriptors, validatePlugins,
            provider: members[choice]);
      }
      return;
    }
    if (!document.existsOnDisk) {
      await _menu('Choose and save your provider and model first', ['Back']);
      return;
    }
    final descriptor = descriptorByIdFor(id, config.descriptors);
    if (descriptor == null) return;
    final wire = descriptor.wire;
    final model = config.model;
    final automaticOutput =
        descriptor.models[model]?.maxOutput ?? config.maxOutputTokens;
    final initialOutput = settings?.maxOutput?.toString() ?? '';
    var output =
        TextLineInput(buffer: initialOutput, cursor: initialOutput.length);
    var replaceOutput = true;
    final localEffort = settings?.reasoningEffort;
    final localBudget = settings?.thinkingBudget;
    final effort =
        localEffort ?? (localBudget == null ? config.reasoningEffort : null);
    final budget =
        localEffort == null ? localBudget ?? config.thinkingBudget : null;
    final efforts = thinkingChoicesFor(model).toList();
    final labels = [
      for (final value in efforts)
        switch (value) {
          'auto' => 'Automatic',
          'none' => 'Off',
          _ => value[0].toUpperCase() + value.substring(1),
        },
    ];
    String? effectiveEffort = effort;
    try {
      effectiveEffort = generationFor(config, id, model).reasoningEffort;
    } on FormatException {
      // An unsupported legacy field is replaced by the single selected choice.
    }
    var thinking = efforts.indexOf(effectiveEffort ?? 'auto');
    if (thinking < 0 &&
        effectiveEffort != null &&
        !model.split('/').last.toLowerCase().startsWith('glm-')) {
      efforts.add(effectiveEffort);
      labels
          .add(effectiveEffort[0].toUpperCase() + effectiveEffort.substring(1));
      thinking = labels.length - 1;
    }
    if (thinking < 0) thinking = 0;
    final customBudget =
        budget != null && wire != ProviderWire.openAiCompatible;
    if (customBudget) {
      if (budget == 0) {
        thinking = 1;
      } else {
        labels.add('Custom (${formatInteger(budget)} tokens)');
        efforts.add('budget');
        thinking = labels.length - 1;
      }
    }
    var selected = 0;
    String? error;
    _paint = () {
      final prefix = '${selected == 0 ? '›' : ' '} Output limit: ';
      final view = textFieldView(output,
          numeric: true,
          width: (dialogArea(screen.layout).width - visibleWidth(prefix))
              .clamp(1, 10000));
      _show([
        'Generation · $id',
        '$prefix${output.buffer.isEmpty ? 'Automatic (${formatInteger(automaticOutput)})' : view.text}',
        '${selected == 1 ? '›' : ' '} Thinking: ${labels[thinking]}',
        error ??
            (selected == 0
                ? '←→ edit · type number · Ctrl-U Automatic'
                : '←→ choose · applies to this provider'),
        '↑↓ select · Enter save · Esc cancel',
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
          final candidate = document.fork();
          final values = candidate.table('providers').putIfAbsent(
              id, () => <String, dynamic>{}) as Map<String, dynamic>;
          for (final key in [
            'max_output',
            'reasoning_effort',
            'thinking_budget'
          ]) {
            values.remove(key);
          }
          values.addAll(fields);
          try {
            generationFor(
                parseTinaConfig(candidate.values, descriptors: descriptors)
                    .config,
                id,
                model);
            document.saveGeneration(id, fields,
                descriptors: descriptors, validatePlugins: validatePlugins);
            _applyGeneration?.call();
            _savedSection = true;
            return;
          } catch (failure) {
            error = failure is FormatException
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

  Future<void> _plugins(
      ConfigDocument document,
      List<String> ids,
      PluginSettings<dynamic>? settings,
      PluginManager<dynamic>? manager,
      Map<String, String> descriptions) async {
    var scope = PluginScope.global;
    var selected = 0;
    var query = '';
    settings?.reload();
    Set<String> requiredIds() => settings?.requiredIds ?? {};
    ids = {...ids, ...requiredIds()}.toList()..sort();
    bool enabled(String id) {
      if (requiredIds().contains(id)) return true;
      if (settings != null) return settings.scopedState(id, scope).enabled;
      final table = document.table('plugins');
      return parsePluginOverrides(table)[id] ??
          pluginBaseline(
                  (table['enabled'] as List? ?? defaultPluginIds)
                      .cast<String>(),
                  selectionVersion: table['selection_version'] as int? ?? 1)
              .contains(id);
    }

    String description(String id) =>
        descriptions[id] ??
        (settings?.registry.ids.contains(id) == true
            ? settings!.registry.definition(id).description
            : '');
    while (true) {
      var reset = false;
      var about = false;
      final rows = [
        'Scope: ${scope.name}',
        for (final id in ids)
          '${enabled(id) ? '[x]' : '[ ]'} $id${requiredIds().contains(id) ? ' · required' : ''}',
        'Approval channel: ${document.table('plugins')['approval_channel'] ?? defaultApprovalChannel}',
      ];
      final choice = await _menu(
          settings == null
              ? 'Plugins (Save changes to apply)'
              : 'Plugins (toggles save immediately)',
          rows,
          initialSelected: selected,
          initialQuery: query,
          onQuery: (value) => query = value,
          checkboxes: true,
          onReset: () => reset = true,
          onAbout: () => about = true,
          descriptionFor: (index) => index > 0 && index <= ids.length
              ? description(ids[index - 1])
              : '',
          detailFor: (index) {
            if (index == 0) return 'Choose where changes apply';
            if (index > ids.length) return 'Save changes; restart required';
            final id = ids[index - 1];
            if (requiredIds().contains(id))
              return settings?.blockingReasons[id]?.join('; ') ??
                  'Required by selected plugins';
            if (settings == null) return 'Save changes to apply';
            final active =
                manager!.host.plugins.any((plugin) => plugin.id == id);
            return '${settings.changeStatus(id, manager)} · active ${active ? 'on' : 'off'} · ${settings.scopedState(id, scope).source}';
          });
      if (choice == null) return;
      selected = choice;
      try {
        if (about) {
          if (choice > 0 && choice <= ids.length) {
            final id = ids[choice - 1];
            List<String> lines() => wrapDialogText(
                description(id), dialogArea(screen.layout).width - 2);
            await _menu('About $id', lines(), itemsNow: lines);
          }
          continue;
        }
        if (choice == 0) {
          if (settings == null) continue;
          final chosen =
              await _menu('Plugin scope', ['Global', 'Workspace', 'Session']);
          if (chosen != null)
            scope = [
              PluginScope.global,
              PluginScope.workspace,
              PluginScope.session
            ][chosen];
        } else if (choice <= ids.length) {
          final id = ids[choice - 1];
          if (requiredIds().contains(id)) continue;
          if (settings != null) {
            settings.apply(id, reset ? null : !enabled(id), scope, manager!);
            if (scope == PluginScope.global) {
              final channel = document.table('plugins')['approval_channel'];
              document.refreshTable('plugins');
              if (channel != null)
                document.table('plugins')['approval_channel'] = channel;
            }
            if (manager.lastError != null)
              await _menu(
                  'Plugin change pending', [manager.lastError!, 'Back']);
          } else {
            final table = document.table('plugins');
            final overrides =
                Map<String, dynamic>.from(table['overrides'] as Map? ?? {});
            if (reset) {
              overrides.remove(id);
            } else {
              overrides[id] = !enabled(id);
            }
            table['overrides'] = overrides;
          }
        } else {
          final table = document.table('plugins');
          final value = await _edit(
              'Approval channel (Save changes; restart required)',
              table['approval_channel'] as String? ?? defaultApprovalChannel,
              suggestions: ids.where((id) => id.contains('approval')).toList());
          if (value != null) table['approval_channel'] = value.trim();
        }
      } catch (error) {
        await _menu('Could not change plugin', [
          error is ArgumentError
              ? error.message.toString()
              : error is StateError
                  ? error.message.toString()
                  : 'Check the configuration and file permissions.',
          'Back'
        ]);
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
            }
        ];
      }

      final selected = await _menu(section.title, items(),
          itemsNow: items,
          valid: () => registry.contains(section),
          keysNow: () => controls.map((c) => c.id).toList(),
          onSelected: (index) => chosen = controls[index]);
      if (selected == null || !registry.contains(section)) return;
      final control = chosen!;
      // Unloading while an editor is open invalidates its callback.
      bool available() =>
          registry.contains(section) &&
          section.build().any((c) => c.id == control.id);
      try {
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
        }
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

  Future<void> _defaultModel(
      ConfigDocument document, List<ProviderDescriptor> descriptors) async {
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
      final descriptor = descriptorByIdFor(id, descriptors);
      final values = providers[id];
      final settings = values is Map<String, dynamic>
          ? ProviderSettings.parse(id, values)
          : const ProviderSettings();
      names[id] =
          (values as Map?)?['name'] as String? ?? descriptor?.name ?? id;
      final models = <String, ModelInfo>{
        ...?descriptor?.models,
        ...?settings.models
      };
      for (final model in models.values) {
        if (settings.disabledModels.contains(model.id)) continue;
        refs.add('$id/${model.id}');
        modelNames['$id/${model.id}'] = model.name;
      }
      final current = defaults['model'] as String? ?? '';
      if (id == currentId &&
          current.isNotEmpty &&
          !settings.disabledModels.contains(current) &&
          !refs.contains('$id/$current')) refs.add('$id/$current');
    }
    final picker = ModelSearchPicker(
        screen: screen,
        modelRefs: refs,
        providerNames: names,
        modelNames: modelNames,
        title: 'Choose default model',
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
    } finally {
      _paint = null;
    }
  }

  Future<void> _providers(
      ConfigDocument document,
      List<ProviderDescriptor> descriptors,
      void Function(Iterable<String>)? validatePlugins) async {
    final draft = document.fork();
    late final ProvidersPanel panel;
    panel = ProvidersPanel(
        screen: screen,
        readEvent: _formEvent,
        providers: draft.table('providers'),
        descriptors: descriptors,
        editAdvanced: (id) => _providerFields(
            draft, descriptors, validatePlugins, id,
            generationDocument: document),
        onShow: () => _paint = panel.repaint);
    _overlay.hide();
    try {
      if (await panel.run())
        document.values['providers'] = draft.table('providers');
    } finally {
      _paint = null;
    }
  }

  Future<void> _providerFields(
      ConfigDocument document,
      List<ProviderDescriptor> descriptors,
      void Function(Iterable<String>)? validatePlugins,
      String id,
      {ConfigDocument? generationDocument}) async {
    final providers = document.table('providers');
    final ids = {...descriptors.map((d) => d.id), ...providers.keys}.toList();
    final values = providers.putIfAbsent(id, () => <String, dynamic>{})
        as Map<String, dynamic>;
    final builtin = descriptorByIdFor(id, descriptors);
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
              : '${labels[i]}: ${_preview(fields[i], values[fields[i]])}',
        'Back',
      ]);
      if (choice == null || choice == fields.length) break;
      final field = fields[choice];
      if (field == 'generation') {
        final target = generationDocument ?? document;
        await _generation(target, descriptors, validatePlugins, provider: id);
        if (!identical(target, document)) {
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

  Future<void> _field(Map<String, dynamic> values, String key, String label,
      {bool secret = false,
      bool list = false,
      bool numeric = false,
      List<String> suggestions = const []}) async {
    final old = values[key];
    final value = await _edit(
        label, old is List ? old.join(', ') : old?.toString() ?? '',
        secret: secret, numeric: numeric, suggestions: suggestions);
    if (value == null) return;
    if (numeric && value.isNotEmpty) {
      final number = int.tryParse(value);
      if (number == null || number < 0) {
        await _menu('Enter a nonnegative integer', ['Back']);
        return;
      }
      values[key] = number;
    } else if (list) {
      values[key] = _list(value);
    } else if (value.isEmpty) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }

  void _show(List<String> lines, {(int, int)? cursor}) {
    final area = dialogArea(screen.layout);
    final visible = lines
        .take(area.height)
        .map((v) => clipDialogText(v, area.width))
        .toList();
    final bounds = centeredDialog(screen.layout, visible);
    screen.frame(() {
      _overlay.update(bounds: bounds, lines: visible);
      if (cursor != null && bounds.height > 0 && bounds.width > 0) {
        screen.parkCursorAt(bounds.row + cursor.$1.clamp(0, bounds.height - 1),
            bounds.col + cursor.$2.clamp(0, bounds.width - 1));
      }
    });
  }

  Future<int?> _menu(String title, List<String> items,
      {int initialSelected = 0,
      String initialQuery = '',
      void Function(String)? onQuery,
      bool checkboxes = false,
      String Function(int)? detailFor,
      String Function(int)? descriptionFor,
      void Function()? onAbout,
      void Function()? onReset,
      List<String> Function()? itemsNow,
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
      final filtered = matches();
      if (filtered.isEmpty) {
        _show([title, 'Find: $query', 'No matches · backspace to edit']);
        return;
      }
      selected = selected.clamp(0, filtered.length - 1);
      final keys = keysNow?.call() ?? items;
      if (selectedKey != null) {
        final previous = filtered.indexWhere((i) => keys[i] == selectedKey);
        if (previous >= 0) selected = previous;
      }
      selectedKey = keys[filtered[selected]];
      final area = dialogArea(screen.layout);
      final blurb = descriptionFor?.call(filtered[selected]) ?? '';
      final description =
          blurb.isEmpty ? <String>[] : wrapDialogText(blurb, area.width);
      final descriptionRoom =
          (area.height - (query.isEmpty ? 4 : 5)).clamp(0, description.length);
      final descriptionLines = description.take(descriptionRoom).toList();
      if (descriptionLines.isNotEmpty && descriptionRoom < description.length) {
        descriptionLines[descriptionLines.length - 1] =
            clipDialogText('${descriptionLines.last} …', area.width);
      }
      final room = (area.height -
              descriptionLines.length -
              (query.isEmpty ? 2 : 3) -
              (detailFor == null ? 0 : 1))
          .clamp(1, filtered.length);
      final start = (selected - room + 1).clamp(0, filtered.length - room);
      _show([
        title,
        if (query.isNotEmpty) 'Find: $query',
        for (var i = start; i < start + room; i++)
          '${selected == i ? '›' : ' '} ${items[filtered[i]]}',
        ...descriptionLines,
        if (detailFor != null) detailFor(filtered[selected]),
        checkboxes
            ? 'space toggle · ^R inherit · ? about · esc'
            : '↑↓ move · type to find · enter select · esc back'
      ]);
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
        case CharInput(text: ' ') when checkboxes:
          if (filtered.isNotEmpty) {
            onQuery?.call(query);
            return filtered[selected];
          }
        case ControlKey(code: ControlCode.ctrlR) when checkboxes:
        case ControlKey(code: ControlCode.backspace)
            when checkboxes && query.isEmpty:
          if (filtered.isNotEmpty) {
            onReset?.call();
            onQuery?.call(query);
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
          width: dialogArea(screen.layout).width,
          secret: secret,
          numeric: numeric);
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
