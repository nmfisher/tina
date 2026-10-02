import 'package:tina_settings/tina_settings.dart';

final subagentSettings = <SettingDefinition<int>>[
  for (final field in const {
    'max_sub_agent_depth': 'Subagent depth',
    'max_sub_agent_concurrency': 'Concurrent subagents',
  }.entries)
    SettingDefinition<int>(
        id: 'tina/subagents/${field.key}',
        label: field.value,
        description:
            'Maximum ${field.value.toLowerCase()} for this conversation. Applies to future spawns; running subagents continue.',
        defaultValue: 3,
        kind: SettingKind.integer,
        minimum: 0,
        applyAt: ApplyAt.nextRequest,
        configPath: ['limits', field.key]),
];
