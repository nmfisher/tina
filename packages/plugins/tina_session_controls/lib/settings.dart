import 'package:tina_settings/tina_settings.dart';

/// The reasoning effort levels every wire accepts. Providers may restrict
/// this per model (see thinkingChoicesFor in tina's provider assembly); the
/// canonical set stays small so /reasoning and the settings panel agree.
const reasoningEffortWords = <String>[
  'auto',
  'none',
  'minimal',
  'low',
  'medium',
  'high',
  'xhigh',
  'max',
];

/// The conversation's reasoning effort: `default.reasoning_effort`, writable
/// from the session by /reasoning. Auto removes the override entirely —
/// the config file's value (or the provider default) applies again. Applies
/// at the next request without resetting the session.
final reasoningSetting = SettingDefinition<String>(
  id: 'tina/session-controls/reasoning',
  label: 'Reasoning effort',
  description:
      'How hard the model thinks on this conversation. Auto removes the override, '
      'restoring the configured or provider default. Applies to the next request.',
  defaultValue: 'auto',
  kind: SettingKind.choice,
  choices: reasoningEffortWords,
  applyAt: ApplyAt.nextRequest,
  readConfig: (document) =>
      (document['default'] as Map?)?['reasoning_effort'] as String?,
  writeConfig: (document, value) {
    if (value == null && (document['default'] as Map?) == null) return;
    final defaults = document.putIfAbsent('default', () => <String, dynamic>{})
        as Map<String, dynamic>;
    if (value == null) {
      defaults.remove('reasoning_effort');
      if (defaults.isEmpty) document.remove('default');
      return;
    }
    defaults['reasoning_effort'] = value;
  },
);

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
      if (defaults?['model'] != null) 'model': defaults!['model'],
    };
  },
  writeConfig: (document, value) {
    final defaults =
        document.putIfAbsent('default', () => <String, dynamic>{})
            as Map<String, dynamic>;
    defaults.remove('provider');
    defaults.remove('model');
    if (value != null) defaults.addAll(Map<String, dynamic>.from(value as Map));
  },
);
