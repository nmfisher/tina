import 'package:tina_engine/tina_engine.dart';

/// AI SDK packages whose wire format tina can actually speak. Everything else
/// models.dev lists (Anthropic, Google, Azure, Bedrock, Vertex, the one-off
/// community packages) is skipped rather than guessed: a row whose requests
/// could never be built is worse than no row at all.
const _openAiCompatibleNpm = <String>{
  '@ai-sdk/openai-compatible',
  '@ai-sdk/openai',
  '@ai-sdk/groq',
  '@ai-sdk/cerebras',
  '@ai-sdk/xai',
  '@ai-sdk/mistral',
  '@ai-sdk/deepinfra',
  '@openrouter/ai-sdk-provider',
};

/// Register the models.dev providers that tina can actually call.
///
/// A provider is seeded only when BOTH hold:
///
/// * **wire** — its `npm` is in [_openAiCompatibleNpm] and it has a base URL
///   and at least one model;
/// * **no collision** — its id is unregistered, and neither its env vars nor
///   its base-URL host match a descriptor tina already had (compiled or
///   config-declared). This is what keeps a models.dev `nvidia` entry from
///   duplicating the compiled `nim` provider (same `NVIDIA_API_KEY`, same host)
///   under a second id. Two *discovered* entries sharing a credential env var
///   are NOT a collision: models.dev lists regional twins (`moonshotai` /
///   `moonshotai-cn`, both `MOONSHOT_API_KEY`) and arbitrarily dropping one
///   would hide the endpoint the user actually needs. Both rows appear, and
///   curation decides.
///
/// Deliberately NOT gated on a credential being present: `/settings` is where
/// a provider gets keyed, so it must list the providers you might key — the
/// same way every compiled provider is listed whether or not you hold its key.
/// Discovery adds ~170 rows; `/settings` search filters them, and
/// `COCOON_MODELS_DEV=0` turns the whole feed off.
///
/// Seeded providers land in the registry but stay out of `/model` and
/// `/spawn` until the user checks them in `/settings`: those pickers only
/// offer providers with a `[providers.<id>]` config block, and
/// `disabledModelRefsFor` disables every model of a provider that has none.
/// Nothing is written to `~/.tina/config` here.
///
/// Returns the number of providers newly registered.
int registerModelsDevProviders({
  required ProviderRegistry registry,
  required Map<String, ModelsDevProviderInfo> providers,
}) {
  var added = 0;
  final seeded = <String>{};
  for (final info in providers.values) {
    if (!_openAiCompatibleNpm.contains(info.npm)) continue;
    final baseUrl = info.apiBase;
    if (baseUrl == null || baseUrl.isEmpty) continue;
    // A provider with no models would be an empty picker row, and an empty
    // descriptor catalog breaks the `models.keys.first` default-model path.
    if (info.models.isEmpty) continue;
    if (_collides(registry, info, baseUrl, seeded)) continue;

    final prefix = info.key.toUpperCase();
    registry.register(ProviderDescriptor(
      id: info.key,
      name: info.name,
      authSources: [
        for (final v in info.envVars) AuthSource(v, AuthScheme.bearerToken),
        // A config block for this id exports <ID>_API_KEY regardless of how
        // models.dev names the credential, so honour it last.
        AuthSource('${prefix}_API_KEY', AuthScheme.bearerToken),
      ],
      defaultBaseUrl: baseUrl,
      builder: openAiCompatibleBuilder(info.name),
      models: info.models,
      // The live /v1/models list is authoritative once a key works; the
      // models.dev map above is the fallback while it loads or if it 401s.
      listsRemoteModels: true,
    ));
    seeded.add(info.key);
    added++;
  }
  return added;
}

bool _collides(
  ProviderRegistry registry,
  ModelsDevProviderInfo info,
  String baseUrl,
  Set<String> seeded,
) {
  if (registry.descriptor(info.key) != null) return true;
  final mdVars = info.envVars.toSet();
  final host = _host(baseUrl);
  for (final d in registry.descriptors) {
    // Another entry from this same feed is a sibling, not a prior claim.
    if (seeded.contains(d.id)) continue;
    if (d.authSources.any((s) => mdVars.contains(s.envVar))) return true;
    if (host != null && _host(d.defaultBaseUrl) == host) return true;
  }
  return false;
}

String? _host(String url) {
  final uri = Uri.tryParse(url);
  return uri == null || uri.host.isEmpty ? null : uri.host;
}
