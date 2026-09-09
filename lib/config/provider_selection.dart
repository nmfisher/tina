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

/// Whether two `[providers]` maps hold the same blocks. [ProviderConfig] is a
/// value type, so this is an exact comparison — the signal that a config file
/// gained, lost or edited a provider block since it was last registered, used
/// to skip a re-registration whose only effects would be resets (a pool's
/// warn-once flag) and repeated warnings.
bool sameProviderBlocks(
  Map<String, ProviderConfig> a,
  Map<String, ProviderConfig> b,
) {
  if (a.length != b.length) return false;
  for (final entry in a.entries) {
    if (b[entry.key] != entry.value) return false;
  }
  return true;
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
  Iterable<String> providerIds,
  List<String> Function(String providerId) modelIdsFor,
) {
  final out = <String>{};
  for (final pid in providerIds) {
    final disabled = cfg.providers[pid]?.disabledModels;
    if (disabled == null) {
      for (final mid in modelIdsFor(pid)) {
        out.add('$pid/$mid');
      }
    } else {
      for (final mid in disabled) {
        out.add('$pid/$mid');
      }
    }
  }
  return out;
}
