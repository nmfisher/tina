import 'package:tina_engine/tina_engine.dart';

import '../config.dart';
import '../config/user_config.dart';

/// One convention for turning a `"provider/model"` ref into a registry call.
///
/// Every call site that builds a provider from a ref — startup/restore
/// resolution, the TUI's provider factory, and the `/spawn`, `/branch` and
/// `/model` overlays — used to hand-roll the same steps with small copy-paste
/// drift between them. This file owns them (plugin_architecture.md §4.5: no
/// new seam — the registry is the seam; this is its one shared client):
///
/// - [refProviderForBuild] — the slash parse (null when the ref has no `/`,
///   i.e. a bare model on the ambient provider).
/// - [appliesToStartupProvider] — the sameProvider rule: the startup API key
///   and base URL belong to the CONFIG provider only; a different provider
///   resolves afresh from its descriptor + environment.
/// - [buildResolved] — one forwarding call: the startup key/base URL when they
///   apply, plus the config's tuning knobs (maxTokens, streamIdleTimeout,
///   requestTimeout). An override still only reaches the registry when its
///   provider matches — a key minted for one vendor must not be sent to
///   another.
/// - [apiKeyForPickedRef] — the TUI overlays' `[providers.<id>] key` lookup
///   for a picked ref (null → the registry falls back to the descriptor's
///   auth sources).
///
/// Deliberately NOT here: fallback, warning, and error reporting. An
/// unresolvable ref degrades differently per path (a stderr warning at
/// startup, a silent account-provider fallback on restore, an inline error
/// message in the TUI), so callers keep their own try/catch around
/// [buildResolved].
String? refProviderForBuild(String ref) =>
    ref.contains('/') ? ref.split('/').first : null;

/// Whether a build of [ref] may inherit the startup-provided key/base URL:
/// true only when the ref names [configProvider] explicitly
/// (`"<configProvider>/..."`). A ref with no `/` is a bare model id: the
/// registry then resolves key AND base URL from the descriptor's own auth
/// sources and default, with nothing inherited — the historical
/// session-restore behavior. (`buildStartupProvider` never consults this for
/// bare refs: they take its warn-and-fallback path before any build.)
bool appliesToStartupProvider(String ref, String configProvider) =>
    refProviderForBuild(ref) == configProvider;

/// Build [ref] under [config]'s tuning and the sameProvider rule, returning
/// whatever the registry builds. Throws what the registry throws (e.g.
/// [ProviderRegistryException]) — callers own fallback and reporting.
LlmProvider buildResolved(
  ProviderRegistry registry,
  Config config,
  String ref, {
  String? apiKeyOverride,
  String? baseUrlOverride,
}) {
  final sameProvider = appliesToStartupProvider(ref, config.provider);
  return registry.build(
    ref,
    apiKeyOverride: sameProvider ? apiKeyOverride : null,
    baseUrlOverride: sameProvider ? baseUrlOverride : null,
    maxTokens: config.maxTokens,
    streamIdleTimeout: config.streamIdleTimeout,
    requestTimeout: config.requestTimeout,
  );
}

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
