import 'dart:convert';
import 'dart:io';
import 'builtin_descriptors.dart';
import 'descriptor.dart';
import 'models_dev.dart';

/// Read the legacy discovery cache offline. Compiled endpoint/auth definitions
/// win; supported discovered providers fill gaps. No refresh or cache writes.
List<ProviderDescriptor> cachedProviderDescriptors(String path,
    {List<ProviderDescriptor> builtins = builtinDescriptors}) {
  final result = {for (final d in builtins) d.id: d};
  final Map<String, dynamic> raw;
  try {
    raw = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
  } catch (_) {
    return List.unmodifiable(result.values);
  }
  const packages = {
    '@ai-sdk/openai-compatible',
    '@ai-sdk/openai',
    '@ai-sdk/groq',
    '@ai-sdk/cerebras',
    '@ai-sdk/xai',
    '@ai-sdk/mistral',
    '@ai-sdk/deepinfra',
    '@openrouter/ai-sdk-provider',
  };
  for (final entry in raw.entries) {
    if (result.containsKey(entry.key) ||
        !RegExp(r'^[a-zA-Z][a-zA-Z0-9_-]*$').hasMatch(entry.key)) continue;
    try {
      final row = entry.value as Map<String, dynamic>;
      if (!packages.contains(row['npm'])) continue;
      final base = row['api'] as String;
      final url = Uri.parse(base);
      if (!['http', 'https'].contains(url.scheme) ||
          url.host.isEmpty ||
          url.userInfo.isNotEmpty ||
          url.hasQuery ||
          url.hasFragment) continue;
      final env = (row['env'] as List? ?? [])
          .cast<String>()
          .where((s) => RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(s))
          .toList();
      final models = <String, ModelInfo>{};
      for (final model in (row['models'] as Map<String, dynamic>).entries) {
        try {
          models[model.key] = modelsDevModelInfo(
              model.key, model.value as Map<String, dynamic>);
        } catch (_) {/* A malformed model must not hide other usable models. */}
      }
      if (models.isEmpty) continue;
      result[entry.key] = ProviderDescriptor(
          id: entry.key,
          name: row['name'] as String? ?? entry.key,
          wire: ProviderWire.openAiCompatible,
          baseUrl: base,
          keyEnvVar: env.isEmpty ? '' : env.first,
          fallbackKeyEnvVars: env.skip(1).toList(),
          keyStyle: ProviderKeyStyle.bearer,
          models: Map.unmodifiable(models));
    } catch (_) {/* Unsupported or damaged cache rows are not providers. */}
  }
  return List.unmodifiable(result.values);
}
