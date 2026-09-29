import 'dart:io';
import 'dart:math' as math;
import 'package:tina_providers/tina_providers.dart';
import 'package:tina_core/tina_core.dart';
import 'package:tina_llm/tina_llm.dart';
import 'assembly_config.dart';

/// Config values override environment values; named providers keep their own
/// endpoint and credentials. The same factory builds foreground and child runs.
LlmProvider configuredProvider(
  TinaConfig config,
  String model, {
  Map<String, String>? environment,
  HttpEndpoint? endpoint,
  String? providerId,
}) {
  final env = environment ?? Platform.environment;
  final id = providerId ?? config.providerId ?? 'anthropic';
  final settings = config.providers[id];
  final descriptor = descriptorByIdFor(id, config.descriptors);
  final generation = generationFor(config, id, model);
  if (providerId == null &&
      config.providerId == null &&
      settings == null &&
      environment == null) {
    return AnthropicProvider(
        model: model, endpoint: endpoint, generation: generation);
  }
  if (descriptor == null) throw StateError('unknown configured provider');
  final prefix = providerEnvPrefix(id);
  String? nonempty(String? value) =>
      value == null || value.isEmpty ? null : value;
  final configAuth = nonempty(settings?.authToken);
  final configKey = nonempty(settings?.apiKey);
  final genericToken =
      id == 'anthropic' ? nonempty(env['TINA_LLM_TOKEN']) : null;
  final envAuth = nonempty(env['${prefix}_AUTH_TOKEN']);
  final descriptorKey = [descriptor.keyEnvVar, ...descriptor.fallbackKeyEnvVars]
      .map((key) => nonempty(env[key]))
      .whereType<String>()
      .firstOrNull;
  final token = configAuth ??
      configKey ??
      genericToken ??
      envAuth ??
      descriptorKey ??
      nonempty(env['${prefix}_API_KEY']) ??
      nonempty(env['${id.toUpperCase()}_API_KEY']) ??
      '';
  final bearer = configAuth != null ||
      (configKey == null &&
          (genericToken != null ||
              envAuth != null ||
              (descriptorKey != null &&
                  descriptor.keyStyle == ProviderKeyStyle.bearer)));
  final base = settings?.baseUrl ??
      nonempty(env['${prefix}_BASE_URL']) ??
      (id == 'anthropic' ? nonempty(env['TINA_LLM_ENDPOINT']) : null) ??
      descriptor.baseUrl;
  return switch (descriptor.wire) {
    ProviderWire.anthropic => AnthropicProvider(
        model: model,
        generation: generation,
        endpoint: endpoint,
        endpointUrl: base,
        tokenFrom: () => token,
        bearerToken: bearer),
    ProviderWire.openAiCompatible => OpenAiCompatibleProvider(
        model: model,
        generation: generation,
        baseUrl: base,
        endpoint: endpoint,
        tokenFrom: () => token),
    ProviderWire.gemini => GeminiProvider(
        model: model,
        generation: generation,
        baseUrl: base,
        endpoint: endpoint,
        tokenFrom: () => token),
  };
}

/// Known model restrictions shared by the UI and request construction.
/// GLM-5.3 family: https://docs.z.ai/guides/capabilities/thinking
/// Coding-plan aliases accept extra spellings, but those do not represent
/// additional choices (e.g. "none" still thinks at low effort).
List<String> thinkingChoicesFor(String model) {
  final name = model.split('/').last.toLowerCase();
  if (name.startsWith('glm-5.3')) return const ['auto', 'low', 'high', 'max'];
  if (name.startsWith('glm-5.2')) return const ['auto', 'none', 'high', 'max'];
  if (name.startsWith('glm-')) return const ['auto'];
  return const ['auto', 'none', 'low', 'medium', 'high'];
}

String? _modelEffort(String model, String? effort) {
  if (effort == null) return null;
  final name = model.split('/').last.toLowerCase();
  if (name.startsWith('glm-5.3')) {
    return switch (effort) {
      'none' || 'minimal' || 'low' => 'low',
      'medium' || 'high' => 'high',
      'xhigh' || 'max' => 'max',
      _ => effort,
    };
  }
  if (name.startsWith('glm-5.2')) {
    return switch (effort) {
      'low' || 'medium' => 'high',
      'xhigh' => 'max',
      _ => effort,
    };
  }
  return effort;
}

GenerationOptions generationFor(TinaConfig config, String id, String model) {
  final settings = config.providers[id];
  final descriptor = descriptorByIdFor(id, config.descriptors)!;
  // A provider's thinking choice is one override, not two independently
  // inherited fields. Automatic explicitly requests the provider's defaults.
  final localEffort = settings?.reasoningEffort;
  final localBudget = settings?.thinkingBudget;
  final chosenEffort =
      localEffort ?? (localBudget != null ? null : config.reasoningEffort);
  final effort =
      _modelEffort(model, chosenEffort == 'auto' ? null : chosenEffort);
  final budget = localEffort != null
      ? null
      : localBudget ?? (chosenEffort == 'auto' ? null : config.thinkingBudget);
  // The global value is a fallback, not a ceiling on provider/model settings.
  final maxOutput = settings?.maxOutput ??
      descriptor.models[model]?.maxOutput ??
      config.maxOutputTokens;
  if (effort != null &&
      !['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max']
          .contains(effort))
    throw FormatException('invalid reasoning_effort for $id');
  switch (descriptor.wire) {
    case ProviderWire.openAiCompatible:
      if (budget != null)
        throw FormatException(
            'thinking_budget is not supported by the OpenAI-compatible wire; use reasoning_effort');
    case ProviderWire.anthropic:
      if (effort == 'minimal')
        throw FormatException('Anthropic wire does not support minimal effort');
      if (budget != null &&
          budget != 0 &&
          (budget < 1024 || budget >= maxOutput))
        throw FormatException(
            'Anthropic thinking_budget must be 0 or at least 1024 and below max_tokens');
    case ProviderWire.gemini:
      if (effort != null &&
          !['none', 'minimal', 'low', 'medium', 'high'].contains(effort))
        throw FormatException(
            'Gemini thinking level must be none, minimal, low, medium or high');
      if (budget != null && effort != null)
        throw FormatException(
            'Gemini accepts either thinking_budget or reasoning_effort, not both');
  }
  return GenerationOptions(
      maxOutputTokens: maxOutput,
      reasoningEffort: effort,
      thinkingBudget: descriptor.wire == ProviderWire.gemini && effort == 'none'
          ? 0
          : budget,
      openAiOutputField: settings?.outputTokenField ??
          (id == 'openai' ? 'max_completion_tokens' : 'max_tokens'));
}

/// Construct one scheduling scope, shared by the main session and its children.
ProviderPolicyPlugin configuredPolicy(TinaConfig config,
    {LlmProvider Function(String)? override}) {
  List<ProviderTarget> targets(String model) {
    final selected = config.providerId ?? 'anthropic';
    if (override != null)
      return [
        ProviderTarget(
            id: 'injected',
            create: () => override(model),
            minInterval: Duration(milliseconds: config.limits.minIntervalMs),
            maxConcurrent: config.limits.maxConcurrent)
      ];
    final members = config.providers[selected]?.members ?? const <String>[];
    return [
      for (final member in members.isEmpty ? [selected] : members)
        _target(config, member, model)
    ];
  }

  // Validate the selected pool's generation settings before opening resources.
  targets(config.model);
  return ProviderPolicyPlugin(targets: targets, limits: config.limits);
}

ProviderTarget _target(TinaConfig config, String member, String fallbackModel) {
  final slash = member.indexOf('/');
  final id = slash < 0 ? member : member.substring(0, slash);
  final model = slash < 0 ? fallbackModel : member.substring(slash + 1);
  final settings = config.providers[id];
  if (settings?.disabledModels.contains(model) ?? false)
    throw FormatException('model $id/$model is disabled');
  generationFor(config, id, model);
  final rpm = settings?.requestsPerMinute;
  final interval = math.max(
      settings?.minIntervalMs ?? config.limits.minIntervalMs,
      rpm == null || rpm == 0 ? 0 : (60000 / rpm).ceil());
  return ProviderTarget(
      id: '$id/$model',
      gateKey: id,
      minInterval: Duration(milliseconds: interval),
      maxConcurrent: config.limits.maxConcurrent,
      create: () => configuredProvider(config, model, providerId: id));
}
