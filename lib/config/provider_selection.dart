import 'user_config.dart';

/// The `[providers.<id>] key` from a loaded [UserConfig] for a picked
/// `"provider/model"` ref — null when the config block doesn't name the ref's
/// provider, so the registry falls back to the provider's configured auth
/// sources (environment variables).
///
/// `/model`'s picker only ever offers `provider/model` refs, but `/spawn` and
/// `/branch` historically tolerated a bare model id (empty provider id → no
/// override); that tolerance is preserved here.
String? apiKeyForPickedRef(String ref, UserConfig cfg) {
  final slash = ref.indexOf('/');
  final providerId = slash >= 0 ? ref.substring(0, slash) : '';
  return cfg.providers[providerId]?.apiKey;
}

/// The `"provider/model"` refs the pickers must not offer.
///
/// [ProviderConfig.disabledModels] being null means the provider's model list
/// was never curated: ALL of its registry models are disabled by default (the
/// 2026-09-09 flip — a newly configured provider offers nothing until models
/// are picked in /settings). An explicitly saved set is honored as-is, and an
/// empty set re-enables everything; the config round-trip preserves that
/// distinction (empty list written and parsed as non-null).
Set<String> disabledModelRefsFor(
  UserConfig cfg,
  List<String> Function(String providerId) modelIdsFor,
) {
  final out = <String>{};
  for (final e in cfg.providers.entries) {
    final disabled = e.value.disabledModels;
    if (disabled == null) {
      for (final mid in modelIdsFor(e.key)) {
        out.add('${e.key}/$mid');
      }
    } else {
      for (final mid in disabled) {
        out.add('${e.key}/$mid');
      }
    }
  }
  return out;
}
