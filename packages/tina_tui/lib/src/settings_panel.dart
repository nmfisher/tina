import 'dart:async';
import 'package:tina_console/tina_console.dart';
import 'package:tina_llm/tina_llm.dart';
import 'assembly_config.dart';
import 'config_document.dart';

/// Built-in fields edit global settings for future launches. Plugin sections
/// supply their own controls and callbacks independently of that document.
final class SettingsPanel {
  SettingsPanel(this.screen, this.editor, {this.readEvent});
  final Screen screen;
  final LineEditor editor;
  final Future<InputEvent> Function()? readEvent;
  late Future<InputEvent> Function() _read;
  late OverlayRegion _overlay;
  void Function()? _paint;
  void repaint() => _paint?.call();
  Completer<void> _changed = Completer<void>();
  Future<InputEvent>? _pendingRead;
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
      Iterable<String> pluginIds = const []}) async {
    descriptors ??= configuredDescriptors();
    final document = ConfigDocument.open(path);
    if (document.table('default')['model'] == kTinaDefaultModel) {
      document.table('default')['model'] = '';
    }
    _read = readEvent ?? editor.captureKeyReader();
    _pendingRead = null;
    final unlisten = sections?.listen(_refresh);
    _overlay =
        OverlayRegion(screen, const Rect(row: 0, col: 0, width: 1, height: 1));
    try {
      while (true) {
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

        final selected = await _menu('Settings', items(), itemsNow: items,
            onSelected: (index) {
          if (index >= 8) chosenSection = currentSections[index - 8];
        });
        if (selected == null) return false;
        if (chosenSection != null) {
          await _section(sections!, chosenSection!);
          continue;
        }
        switch (selected) {
          case 0:
            final providers = document.table('providers');
            final ids =
                {...descriptors.map((d) => d.id), ...providers.keys}.toList();
            final index = await _menu('Default provider', ids);
            if (index != null) defaults['provider'] = ids[index];
          case 1:
            final id = defaults['provider'] as String? ?? 'anthropic';
            final builtin = descriptorByIdFor(id, descriptors);
            final values = document.table('providers')[id];
            final settings = values is Map<String, dynamic>
                ? ProviderSettings.parse(id, values)
                : const ProviderSettings();
            final models = <String, ModelInfo>{
              ...?builtin?.models,
              ...?settings.models,
            }
                .values
                .where((m) => !settings.disabledModels.contains(m.id))
                .toList();
            final index = await _menu('Default model', [
              for (final model in models) '${model.name} (${model.id})',
              'Enter model ID…',
            ]);
            if (index == null) continue;
            if (index < models.length) {
              defaults['model'] = models[index].id;
            } else {
              await _field(defaults, 'model', 'Model ID');
            }
          case 2:
            await _providers(document, descriptors);
          case 3:
            final plugins = document.table('plugins');
            final choice = await _menu('Plugins', [
              'Enabled feature plugins',
              'Approval channel: ${plugins['approval_channel'] ?? defaultApprovalChannel}',
            ]);
            if (choice == 0) {
              final initial = plugins['enabled'] as List? ?? defaultPluginIds;
              final value = await _edit(
                  'Global enabled plugins (replaces global overrides)',
                  initial.join(', '),
                  suggestions: pluginIds.toList());
              if (value != null) {
                plugins['enabled'] = _list(value);
                plugins.remove('overrides');
              }
            } else if (choice == 1) {
              final value = await _edit(
                  'Approval channel plugin ID',
                  plugins['approval_channel'] as String? ??
                      defaultApprovalChannel,
                  suggestions: pluginIds
                      .where((id) => id.contains('approval'))
                      .toList());
              if (value != null) plugins['approval_channel'] = value.trim();
            }
          case 4:
            try {
              document.save(
                  descriptors: descriptors, validatePlugins: validatePlugins);
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
            const keys = [
              'max_global_tokens',
              'max_session_tokens',
              'max_turn_tokens',
              'max_request_tokens',
              'max_sub_agent_tokens',
              'max_sub_agent_depth',
              'max_sub_agent_concurrency',
              'requests_per_minute',
              'min_request_interval_ms',
              'max_concurrent_requests'
            ];
            final index = await _menu('Limits (0 disables token/rate caps)',
                [for (final key in keys) '$key: ${values[key] ?? 'default'}']);
            if (index != null)
              await _field(values, keys[index], keys[index], numeric: true);
          case 6:
            const keys = ['reasoning_effort', 'max_tokens', 'thinking_budget'];
            final index = await _menu('Generation', [
              for (final key in keys)
                '$key: ${defaults[key] ?? 'provider default'}'
            ]);
            if (index != null)
              await _field(defaults, keys[index], keys[index],
                  numeric: index != 0,
                  suggestions: index == 0
                      ? [
                          'none',
                          'minimal',
                          'low',
                          'medium',
                          'high',
                          'xhigh',
                          'max'
                        ]
                      : const []);
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
      _overlay.hide();
      editor.handleResize();
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

  Future<void> _providers(
      ConfigDocument document, List<ProviderDescriptor> descriptors) async {
    while (true) {
      final providers = document.table('providers');
      final ids = {...descriptors.map((d) => d.id), ...providers.keys}.toList();
      final selected = await _menu('Providers', [...ids, 'Add provider…']);
      if (selected == null) return;
      String id;
      if (selected == ids.length) {
        final answer = await _edit('New provider ID', '');
        if (answer == null) continue;
        id = answer.trim();
        if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_-]*$').hasMatch(id) ||
            ids.contains(id)) {
          await _menu(
              'Use a unique provider ID (letters, digits, - or _)', ['Back']);
          continue;
        }
        providers[id] = <String, dynamic>{'wire': 'openai'};
      } else {
        id = ids[selected];
      }
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
          'max_output',
          'reasoning_effort',
          'thinking_budget',
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
          'Output ceiling',
          'Reasoning effort',
          'Thinking token budget',
          'Output token field'
        ];
        final choice = await _menu('Provider: $id', [
          for (var i = 0; i < fields.length; i++)
            '${labels[i]}: ${_preview(fields[i], values[fields[i]])}',
          'Back',
        ]);
        if (choice == null || choice == fields.length) break;
        final field = fields[choice];
        if (field == 'wire') {
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
              numeric: [
                'requests_per_minute',
                'min_request_interval_ms',
                'max_output',
                'thinking_budget'
              ].contains(field),
              suggestions: field == 'members'
                  ? ids
                  : field == 'reasoning_effort'
                      ? [
                          'none',
                          'minimal',
                          'low',
                          'medium',
                          'high',
                          'xhigh',
                          'max'
                        ]
                      : field == 'output_token_field'
                          ? ['max_tokens', 'max_completion_tokens']
                          : ['models', 'disabled_models'].contains(field)
                              ? (builtin?.models.keys.toList() ?? [])
                              : const []);
        }
      }
    }
  }

  String _preview(String field, Object? value) {
    if (value == null) return 'default';
    if (field == 'api_key' || field == 'auth_token') return 'configured';
    return value is List ? value.join(', ') : value.toString();
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
        secret: secret, suggestions: suggestions);
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

  void _show(List<String> lines) {
    final area = dialogArea(screen.layout);
    final visible = lines
        .take(area.height)
        .map((v) => clipDialogText(v, area.width))
        .toList();
    _overlay.update(
        bounds: centeredDialog(screen.layout, visible), lines: visible);
  }

  Future<int?> _menu(String title, List<String> items,
      {List<String> Function()? itemsNow,
      List<String> Function()? keysNow,
      void Function(int)? onSelected,
      bool Function()? valid}) async {
    var selected = 0;
    var query = '';
    String? selectedKey;
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
      final room = (dialogArea(screen.layout).height - (query.isEmpty ? 2 : 3))
          .clamp(1, filtered.length);
      final start = (selected - room + 1).clamp(0, filtered.length - room);
      _show([
        title,
        if (query.isNotEmpty) 'Find: $query',
        for (var i = start; i < start + room; i++)
          '${selected == i ? '›' : ' '} ${items[filtered[i]]}',
        '↑↓ move · type to find · enter select · esc back'
      ]);
    };
    while (true) {
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
        default:
          break;
      }
    }
  }

  Future<String?> _edit(String label, String initial,
      {bool secret = false,
      List<String> suggestions = const [],
      bool Function()? valid}) async {
    var input = TextLineInput(buffer: initial, cursor: initial.length);
    _paint = () {
      final text = secret ? '•' * input.buffer.runes.length : input.buffer;
      final cursor = secret
          ? input.buffer.substring(0, input.cursor).runes.length
          : input.cursor;
      // Keep the cursor and the end of a long value in the visible viewport.
      final width = (dialogArea(screen.layout).width - 2).clamp(1, 10000);
      final before = text.substring(0, cursor);
      final tail = before.runes.toList();
      while (tail.isNotEmpty &&
          visibleWidth(String.fromCharCodes(tail)) >= width) {
        tail.removeAt(0);
      }
      _show([
        label,
        '${String.fromCharCodes(tail)}▏${text.substring(cursor)}',
        '${suggestions.isEmpty ? '' : 'tab complete · '}enter accept · esc cancel · ctrl-u clear'
      ]);
    };
    while (true) {
      if (valid?.call() == false) return null;
      repaint();
      final event = await _nextEvent();
      if (valid?.call() == false) return null;
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
        case ControlKey(code: ControlCode.backspace):
          input = input.backspace();
        case CharInput(:final text):
          input = input.insert(text);
        case PasteInput(:final text):
          input = input.insert(text.replaceAll(RegExp(r'[\r\n]'), ''));
        case ArrowKey(direction: ArrowDirection.left):
          input = input.moveLeft();
        case ArrowKey(direction: ArrowDirection.right):
          input = input.moveRight();
        case EditingKey(action: EditingAction.home):
          input = input.moveHome();
        case EditingKey(action: EditingAction.end):
          input = input.moveEnd();
        case EditingKey(action: EditingAction.delete):
          input = input.deleteForward();
        case EditingKey(action: EditingAction.killToStart):
          input = const TextLineInput();
        default:
          break;
      }
    }
  }
}
