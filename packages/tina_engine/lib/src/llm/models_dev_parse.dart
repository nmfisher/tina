import 'registry.dart';

/// Placeholder metadata for a models.dev entry that carries no `limit` block.
/// Generous rather than restrictive — a too-small window silently truncates
/// long contexts, while a too-large one only risks a provider-side error the
/// user can see and correct. Matches [LiveModelsCatalog]'s defaults and the
/// pair `_configModels` gives declared custom ids.
const int modelsDevDefaultContextWindow = 131072;
const int modelsDevDefaultMaxOutput = 8192;

/// Parse one models.dev model object into a [ModelInfo].
///
/// Shared by [ModelsDevCatalog] (the `models.json` model overlay) and
/// `ModelsDevProviderCatalog` (the `api.json` provider discovery feed) so the
/// two feeds agree on names, limits and capability flags. Missing limits fall
/// back to [modelsDevDefaultContextWindow] / [modelsDevDefaultMaxOutput] rather
/// than dropping the id.
ModelInfo? modelsDevModelInfo(String id, Map<String, dynamic> json) {
  final limit = json['limit'];
  final context = limit is Map ? (limit['context'] as num?)?.toInt() : null;
  final output = limit is Map ? (limit['output'] as num?)?.toInt() : null;
  final mods = json['modalities'];
  final inputs = (mods is Map
          ? (mods['input'] as List?)?.cast<String>()
          : null) ??
      const <String>[];
  return ModelInfo(
    id: id,
    name: (json['name'] as String?) ?? id,
    contextWindow: context ?? modelsDevDefaultContextWindow,
    maxOutput: output ?? modelsDevDefaultMaxOutput,
    supportsTools: json['tool_call'] == true,
    supportsVision: inputs.contains('image'),
  );
}
