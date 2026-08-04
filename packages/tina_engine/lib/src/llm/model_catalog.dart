import 'registry.dart';

/// Resolves the available [ModelInfo]s for a [ProviderDescriptor].
///
/// Two implementations: [CompiledCatalog] returns the descriptor's
/// hand-seeded `models` map verbatim; [ModelsDevCatalog] (see
/// `models_dev_catalog.dart`) overlays the compiled list with the live
/// models.dev registry, so a provider with a sparse hand-seeded map
/// (e.g. just one flagship model) presents a richer list to the
/// `/settings` picker and bare-model resolution.
///
/// The catalog is consulted on top of the compiled map; the compiled
/// map is the source of truth for providers models.dev doesn't know
/// about (e.g. Tencent MaaS, local Ollama).
abstract class ModelCatalog {
  /// Every model the catalog knows about for [desc], in catalog order.
  /// Empty when the catalog has nothing to add (caller falls back to
  /// `desc.models`).
  List<ModelInfo> modelsFor(ProviderDescriptor desc);

  /// Lookup a model by id within [desc]'s namespace. Returns null when
  /// the catalog has no record (caller falls back to `desc.models[id]`).
  ModelInfo? findModel(ProviderDescriptor desc, String modelId);

  /// True iff the catalog has any record for [desc]. Lets bare-model
  /// resolution (e.g. `resolve('gpt-4o')`) treat catalog-only entries
  /// as authoritative, not just decorate the compiled list.
  bool hasAny(ProviderDescriptor desc);

  /// Non-null when the catalog encountered a non-fatal error during load.
  /// Displayed in the settings overlay so users know model data may be
  /// incomplete. The default implementation returns null (no warning).
  String? get loadWarning => null;

  /// Release any resources held by the catalog (HTTP clients, timers, etc.).
  /// No-op by default; [ModelsDevCatalog] closes its HTTP client.
  void close() {}
}

/// The default catalog: returns the [ProviderDescriptor.models] map as-is.
/// Used when no overlay catalog is attached, and as the structural baseline
/// that overlay catalogs fall back to.
class CompiledCatalog implements ModelCatalog {
  const CompiledCatalog();

  @override
  List<ModelInfo> modelsFor(ProviderDescriptor desc) =>
      desc.models.values.toList();

  @override
  ModelInfo? findModel(ProviderDescriptor desc, String modelId) =>
      desc.models[modelId];

  @override
  bool hasAny(ProviderDescriptor desc) => desc.models.isNotEmpty;

  @override
  String? get loadWarning => null;

  @override
  void close() {}
}
