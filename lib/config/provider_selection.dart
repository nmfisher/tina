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
