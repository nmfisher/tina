import 'package:tina_llm/tina_llm.dart';

/// Legacy-compatible provider settings. Credentials are never part of labels.
final class ProviderSettings {
  const ProviderSettings(
      {this.members = const [],
      this.requestsPerMinute,
      this.minIntervalMs,
      this.maxOutput,
      this.reasoningEffort,
      this.thinkingBudget,
      this.outputTokenField,
      this.name,
      this.baseUrl,
      this.wire,
      this.apiKey,
      this.authToken,
      this.models,
      this.disabledModels = const {}});
  final String? name, baseUrl, apiKey, authToken;
  final ProviderWire? wire;
  final Map<String, ModelInfo>? models;
  final Set<String> disabledModels;
  final List<String> members;
  final int? requestsPerMinute, minIntervalMs, maxOutput, thinkingBudget;
  final String? reasoningEffort, outputTokenField;

  factory ProviderSettings.parse(String id, Map<String, dynamic> values) {
    String? string(String key) {
      final value = values[key];
      if (value != null && value is! String) {
        throw FormatException('providers.$id.$key must be a string');
      }
      if ((key == 'api_key' || key == 'auth_token') &&
          value is String &&
          RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
        throw FormatException(
            'providers.$id.$key must not contain control characters');
      }
      return value as String?;
    }

    List<String>? strings(String key) {
      final value = values[key];
      if (value == null) return null;
      if (value is! List || value.any((v) => v is! String)) {
        throw FormatException('providers.$id.$key must be an array of strings');
      }
      return value.cast<String>();
    }

    final rawWire = string('wire');
    final wire = switch (rawWire) {
      null => null,
      'anthropic' => ProviderWire.anthropic,
      'openai' => ProviderWire.openAiCompatible,
      'gemini' => ProviderWire.gemini,
      _ => throw FormatException(
          'providers.$id.wire must be anthropic, openai or gemini'),
    };
    final base = string('base_url');
    if (base != null) {
      final uri = Uri.tryParse(base);
      if (uri == null ||
          !['http', 'https'].contains(uri.scheme) ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw FormatException(
            'providers.$id.base_url must be an HTTP(S) URL without credentials, query or fragment');
      }
    }
    final specs = strings('models');
    final models = specs == null ? null : <String, ModelInfo>{};
    for (final spec in specs ?? <String>[]) {
      final bar = spec.indexOf('|');
      final model = (bar < 0 ? spec : spec.substring(0, bar)).trim();
      final label = bar < 0 ? model : spec.substring(bar + 1).trim();
      if (model.isEmpty || models!.containsKey(model)) {
        throw FormatException(
            'providers.$id.models contains an empty or duplicate model ID');
      }
      models[model] = ModelInfo(
          id: model,
          name: label.isEmpty ? model : label,
          contextWindow: 131072,
          supportsTools: true);
    }
    int? integer(String key, {bool positive = false}) {
      final value = values[key];
      if (value != null && (value is! int || value < (positive ? 1 : 0)))
        throw FormatException(
            'providers.$id.$key must be a ${positive ? 'positive' : 'nonnegative'} integer');
      return value as int?;
    }

    final members = strings('members') ?? const <String>[];
    if (members.toSet().length != members.length ||
        members.any((m) => m.trim().isEmpty))
      throw FormatException(
          'providers.$id.members contains an empty or duplicate member');
    final outputField = string('output_token_field');
    if (outputField != null &&
        !['max_tokens', 'max_completion_tokens'].contains(outputField))
      throw FormatException(
          'providers.$id.output_token_field must be max_tokens or max_completion_tokens');
    return ProviderSettings(
        members: members,
        requestsPerMinute: integer('requests_per_minute'),
        minIntervalMs: integer('min_request_interval_ms'),
        maxOutput: integer('max_output', positive: true),
        reasoningEffort: string('reasoning_effort'),
        thinkingBudget: integer('thinking_budget'),
        outputTokenField: outputField,
        name: string('name'),
        baseUrl: base,
        wire: wire,
        apiKey: string('api_key'),
        authToken: string('auth_token'),
        models: models,
        disabledModels: (strings('disabled_models') ?? []).toSet());
  }

  ProviderDescriptor descriptor(String id, ProviderDescriptor? builtin) {
    if (members.isNotEmpty)
      return ProviderDescriptor(
          id: id,
          name: name ?? id,
          wire: ProviderWire.openAiCompatible,
          baseUrl: '',
          keyEnvVar: '',
          keyStyle: ProviderKeyStyle.bearer,
          models: models ?? const {});
    if ((builtin == null || wire != null) && baseUrl == null) {
      throw FormatException(
          'providers.$id.base_url is required for a custom provider or wire override');
    }
    final protocol = wire ?? builtin?.wire ?? ProviderWire.openAiCompatible;
    return ProviderDescriptor(
        id: id,
        name: name ?? builtin?.name ?? id,
        wire: protocol,
        baseUrl: baseUrl ?? builtin!.baseUrl,
        keyEnvVar: builtin?.keyEnvVar ?? '${providerEnvPrefix(id)}_API_KEY',
        fallbackKeyEnvVars: builtin?.fallbackKeyEnvVars ?? const [],
        keyStyle: protocol == ProviderWire.openAiCompatible
            ? ProviderKeyStyle.bearer
            : ProviderKeyStyle.header,
        models: {
          ...?builtin?.models,
          for (final model in models?.values ?? const <ModelInfo>[])
            model.id: ModelInfo(
                id: model.id,
                name: model.name,
                contextWindow: builtin?.models[model.id]?.contextWindow ??
                    model.contextWindow,
                maxOutput:
                    builtin?.models[model.id]?.maxOutput ?? model.maxOutput,
                supportsTools: builtin?.models[model.id]?.supportsTools ??
                    model.supportsTools,
                supportsVision: builtin?.models[model.id]?.supportsVision ??
                    model.supportsVision),
        });
  }
}

String providerEnvPrefix(String id) =>
    id.toUpperCase().replaceAll(RegExp('[^A-Z0-9]'), '_');
