import 'package:tina_settings/tina_settings.dart';

final themeSetting = SettingDefinition<String>(
    id: 'tina/chat-tui/theme',
    label: 'Theme',
    description: 'Terminal colors shared by every panel in this app.',
    defaultValue: 'default',
    kind: SettingKind.choice,
    choices: const ['default', 'light', 'dark'],
    scopes: const {SettingScope.global},
    scopeReason:
        'One terminal shares one theme across its panels; this preference is global.',
    configPath: const ['theme', 'variant']);

final defaultModelSetting = SettingDefinition<Map<String, dynamic>>(
    id: 'tina/session-controls/default_model',
    label: 'Default provider and model',
    description:
        'Model used by new conversations. Existing conversations keep their selected model.',
    defaultValue: const {'model': 'scripted'},
    kind: SettingKind.object,
    scopes: const {SettingScope.global, SettingScope.workspace},
    applyAt: ApplyAt.newSession,
    scopeReason:
        'Use /model to change this conversation; defaults apply to new conversations.',
    decode: (value) => Map<String, dynamic>.from(value as Map),
    readConfig: (document) {
      final defaults = document['default'] as Map?;
      if (defaults?['model'] == null && defaults?['provider'] == null)
        return null;
      return {
        if (defaults?['provider'] != null) 'provider': defaults!['provider'],
        if (defaults?['model'] != null) 'model': defaults!['model']
      };
    },
    writeConfig: (document, value) {
      final defaults = document.putIfAbsent(
          'default', () => <String, dynamic>{}) as Map<String, dynamic>;
      defaults.remove('provider');
      defaults.remove('model');
      if (value != null)
        defaults.addAll(Map<String, dynamic>.from(value as Map));
    });
