import 'package:tina_settings/tina_settings.dart';

final providerLimitSettings = <SettingDefinition<int>>[
  for (final field in const {
    'max_global_tokens': ('Conversation and subagent token limit', 0),
    'max_session_tokens': ('Session token limit', 0),
    'max_turn_tokens': ('Turn token limit', 0),
    'max_request_tokens': ('Request input token limit', 0),
    'max_sub_agent_tokens': ('Subagent token limit', 0),
    'requests_per_minute': ('Requests per minute', 0),
    'min_request_interval_ms': ('Minimum request interval (ms)', 0),
    'max_concurrent_requests': ('Concurrent requests', 4),
  }.entries)
    SettingDefinition<int>(
      id: 'tina/providers/${field.key}',
      label: field.value.$1,
      description: field.key == 'requests_per_minute'
          ? 'Spaces requests for this conversation and its subagents. Separate conversations have independent counters. 0 means unlimited.'
          : 'Applies to this conversation and its subagents. 0 disables this limit.',
      defaultValue: field.value.$2,
      kind: SettingKind.integer,
      minimum: 0,
      applyAt: ApplyAt.nextRequest,
      configPath: ['limits', field.key],
    ),
];

List<SettingDefinition<Object>> providerGenerationSettings(String provider,
        {int defaultOutput = 8192}) =>
    [
      SettingDefinition<int>(
          id: 'tina/providers/$provider/max_output',
          label: 'Output token limit ($provider)',
          description:
              'Maximum output tokens per request. Inherit to use the model/provider default.',
          defaultValue: defaultOutput,
          kind: SettingKind.integer,
          minimum: 1,
          applyAt: ApplyAt.nextRequest,
          configPath: ['providers', provider, 'max_output']),
      SettingDefinition<Map<String, dynamic>>(
          id: 'tina/providers/$provider/thinking',
          label: 'Thinking ($provider)',
          description:
              'One thinking choice, translated to the provider protocol. Automatic uses provider defaults.',
          defaultValue: const {'reasoning_effort': 'auto'},
          kind: SettingKind.object,
          applyAt: ApplyAt.nextRequest,
          decode: (value) => Map<String, dynamic>.from(value as Map),
          readConfig: (document) {
            final values = (document['providers'] as Map?)?[provider] as Map?;
            if (values == null) return null;
            if (values['reasoning_effort'] != null)
              return {'reasoning_effort': values['reasoning_effort']};
            if (values['thinking_budget'] != null)
              return {'thinking_budget': values['thinking_budget']};
            return null;
          },
          writeConfig: (document, value) {
            if (value == null &&
                (document['providers'] as Map?)?[provider] == null) return;
            final providers = document.putIfAbsent(
                'providers', () => <String, dynamic>{}) as Map<String, dynamic>;
            final values = providers.putIfAbsent(
                provider, () => <String, dynamic>{}) as Map<String, dynamic>;
            values.remove('reasoning_effort');
            values.remove('thinking_budget');
            if (value != null)
              values.addAll(Map<String, dynamic>.from(value as Map));
          }),
    ];
