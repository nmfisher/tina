import 'dart:io';

import 'http.dart';
import 'model_catalog.dart';
import 'pooled_provider.dart';
import 'provider.dart';
import 'provider_rate_limit.dart';
import 'retrying_provider.dart';

/// How a credential sourced from an env var is sent on the wire.
///
/// For providers that reuse [OpenAiCompatibleAdapter] this drives the adapter
/// directly. For custom-wire providers (Anthropic, Gemini) the exact header is
/// baked into their provider class (`x-api-key`, `x-goog-api-key`); there the
/// scheme only records *which env var* supplies the key.
enum AuthScheme {
  apiKeyHeader, // x-api-key (Anthropic default)
  bearerToken, // Authorization: Bearer (OpenAI, most others)
  none, // local servers (Ollama, llama.cpp)
}

/// One way to obtain and send a credential. A provider lists its accepted
/// sources in priority order; the first whose env var is set wins. Pairing
/// scheme-with-env-var is what lets a static descriptor express Anthropic's
/// real behavior: bearer when `ANTHROPIC_AUTH_TOKEN` is set, `x-api-key`
/// otherwise.
class AuthSource {
  final String envVar;
  final AuthScheme scheme;
  const AuthSource(this.envVar, this.scheme);
}

/// Static facts about a model a provider offers.
class ModelInfo {
  final String id; // wire-format model ID
  final String name; // "Claude Sonnet 4"
  final int contextWindow;
  final int maxOutput;
  final bool supportsTools;
  final bool supportsVision;
  final bool supportsCaching;

  /// Extra top-level fields merged into the request body by OpenAI-compatible
  /// providers (e.g. NIM's `{"chat_template_kwargs": {"enable_thinking": true}}`).
  /// Merged last, so a key here overrides the adapter's default. Ignored by
  /// custom-wire providers (Anthropic, Gemini). Empty by default.
  final Map<String, dynamic> extraBody;

  const ModelInfo({
    required this.id,
    required this.name,
    required this.contextWindow,
    required this.maxOutput,
    this.supportsTools = true,
    this.supportsVision = false,
    this.supportsCaching = false,
    this.extraBody = const {},
  });
}

/// Resolved configuration handed to a [ProviderBuilder]. `maxTokens` and
/// `streamIdleTimeout` are Config-level values threaded through here so builders
/// don't each re-read Config — they are NOT per-provider.
class ProviderInstance {
  final String apiKey;
  final String model;
  final String baseUrl;
  final int maxTokens;
  final Duration streamIdleTimeout;
  final Duration requestTimeout;

  /// The [AuthScheme] of the [AuthSource] that supplied [apiKey]. Custom-wire
  /// providers whose header depends on the credential source (Anthropic: bearer
  /// for `ANTHROPIC_AUTH_TOKEN`, `x-api-key` otherwise) read this; the generic
  /// OpenAI-compatible adapter ignores it (it always sends Bearer).
  final AuthScheme authScheme;
  final Map<String, dynamic> options;

  /// Per-model extra request-body fields forwarded from [ModelInfo.extraBody].
  /// Read only by the OpenAI-compatible builder; merged into the POST body.
  final Map<String, dynamic> extraBody;

  const ProviderInstance({
    required this.apiKey,
    required this.model,
    required this.baseUrl,
    required this.maxTokens,
    required this.streamIdleTimeout,
    required this.requestTimeout,
    required this.authScheme,
    this.options = const {},
    this.extraBody = const {},
  });
}

/// Builds a concrete [LlmProvider] from a resolved [ProviderInstance].
typedef ProviderBuilder = LlmProvider Function(ProviderInstance config);

/// Wraps a built [LlmProvider] to cross-cut every provider the app constructs —
/// the one place spend metering / rate-limiting ([MeteringProvider]) is applied
/// so it covers the startup, per-conversation, and sub-agent providers alike.
/// Set on the registry by the composition root BEFORE the first [build] call;
/// `null` (the default) leaves providers unwrapped, preserving old behavior.
typedef ProviderDecorator = LlmProvider Function(LlmProvider inner);

/// Metadata about a provider family — pure data, no wire-format logic.
class ProviderDescriptor {
  /// Unique identifier, e.g. "anthropic", "openai", "ollama", "groq".
  final String id;

  /// Human-readable name, e.g. "Anthropic", "OpenAI".
  final String name;

  /// Credential sources in priority order; the first whose env var is set wins.
  final List<AuthSource> authSources;

  /// Default base URL, WITHOUT a guaranteed version segment — builders
  /// normalize per their wire format.
  final String defaultBaseUrl;

  /// Factory that builds the concrete [LlmProvider].
  final ProviderBuilder builder;

  /// Models this provider offers (embedded catalog). May be empty for
  /// providers that rely on dynamic discovery (e.g. local servers).
  final Map<String, ModelInfo> models;

  /// Whether the provider exposes an OpenAI-compatible `GET /v1/models`
  /// endpoint that lists the models actually servable with the user's key.
  /// When true, [LiveModelsCatalog] fetches that list at startup and layers
  /// it over this compiled map (which then serves as metadata enrichment —
  /// context windows, tool support — rather than the catalog itself).
  final bool listsRemoteModels;

  /// The endpoint's known per-key request ceiling, in requests per minute —
  /// a hint the registry installs on [ProviderRegistry.rateLimiter] as the
  /// per-queue-key spacing (60 s / [requestsPerMinute]) when this descriptor
  /// builds a provider. Null (the default) means "no evidence for a ceiling":
  /// the queue key falls back to the registry-wide [ProviderRateLimiter
  /// .minInterval]. A user override via [ProviderRegistry.setRequestRate]
  /// always wins over this hint.
  final int? requestsPerMinute;

  const ProviderDescriptor({
    required this.id,
    required this.name,
    required this.authSources,
    required this.defaultBaseUrl,
    required this.builder,
    this.models = const {},
    this.listsRemoteModels = false,
    this.requestsPerMinute,
  });
}

/// A parsed `"provider/model"` reference. [providerId] is null for a bare
/// model name, in which case the registry searches all providers.
class ModelReference {
  final String? providerId;
  final String modelId;

  const ModelReference(this.providerId, this.modelId);

  /// Parses `"provider/model"` or a bare `"model"`. Splits on the **first**
  /// slash only — model ids may themselves contain slashes (e.g. OpenRouter's
  /// `anthropic/claude-3.5-sonnet`), so `openrouter/anthropic/claude-3.5-sonnet`
  /// parses to provider=`openrouter`, model=`anthropic/claude-3.5-sonnet`.
  static ModelReference parse(String input) {
    final slash = input.indexOf('/');
    if (slash == -1) return ModelReference(null, input);
    return ModelReference(
        input.substring(0, slash), input.substring(slash + 1));
  }

  @override
  String toString() => providerId == null ? modelId : '$providerId/$modelId';
}

/// A [ProviderDescriptor] paired with the concrete model id to use.
class ResolvedModel {
  final ProviderDescriptor descriptor;
  final String modelId;
  const ResolvedModel(this.descriptor, this.modelId);
}

/// Thrown by [ProviderRegistry] for unknown/ambiguous providers or models,
/// or when a required API key is missing.
class ProviderRegistryException implements Exception {
  final String message;
  const ProviderRegistryException(this.message);
  @override
  String toString() => 'ProviderRegistryException: $message';
}

/// Holds registered [ProviderDescriptor]s and resolves `"provider/model"`
/// references into concrete [LlmProvider]s.
///
/// Constructed once in `main()` and threaded into the components that build
/// providers — the same injection pattern as the existing `providerFactory` /
/// `agentBuilder` typedefs. NOT a static singleton: the codebase keeps global
/// state out of testable boundaries (docs/testing_architecture.md), and the
/// registry is no exception. The environment map is injectable for tests.
class ProviderRegistry {
  final Map<String, String> _env;
  final Map<String, ProviderDescriptor> _providers = {};

  /// The default maxTokens used when a caller doesn't pass one. Matches the
  /// historical default in [Config] and the existing providers.
  static const int defaultMaxTokens = 8192;

  /// Optional wrapper applied to every built provider. Set by the composition
  /// root (`buildAppComposition`) once the session-scoped [MeteringProvider] /
  /// `SpendLedger` exist — BEFORE the first [build] call, since the startup
  /// provider is built inside that composition step. `null` (the default and in
  /// tests that build a registry directly) leaves providers unwrapped.
  ProviderDecorator? decorator;

  /// Built-in per-provider request spacing, applied inside [build] beneath the
  /// [decorator] so every provider constructed from one descriptor — the
  /// startup provider, side panels, sub-agents, the environment agent — shares
  /// one launch-slot queue. Disabled ([ProviderRateLimiter.minInterval] zero,
  /// the default) until the composition root opts in; the app entrypoint sets
  /// it from the user config.
  final ProviderRateLimiter rateLimiter = ProviderRateLimiter();

  /// Wire retries per send, applied by [RetryingProvider] at the top of the
  /// policy stack (see [build]). Zero (the default) means no retry layer —
  /// providers stay single-attempt and the built provider keeps its concrete
  /// type in tests. The app entrypoint sets the historical transport count
  /// (3); a retry re-enters the rate limiter, so it can never stampede.
  int maxSendRetries = 0;

  /// Per-provider user override for the request-rate ceiling, in requests per
  /// minute — from `[providers.<id>] requests_per_minute`. Consulted by
  /// [_buildLimited] AHEAD of the descriptor's own [ProviderDescriptor
  /// .requestsPerMinute] hint (which itself beats the registry-wide
  /// [rateLimiter.minInterval] default). 0 disables spacing for that
  /// provider's queues (the key keeps only the concurrency cap); null
  /// (absent, the default) means "no override" — the descriptor hint or the
  /// global default applies.
  final Map<String, int> _requestRates = {};

  /// Install (or replace) the user's per-provider request-rate override for
  /// [providerId], in requests per minute. 0 disables spacing for every queue
  /// key this provider builds; a positive value spaces each of its keys at
  /// 60 s / [rpm] (rounded up to whole ms). Idempotent — the interval is
  /// (re)installed lazily and idempotently when the provider next builds, so
  /// calling this any time before/around [build] is safe.
  void setRequestRate(String providerId, int rpm) {
    if (rpm < 0) {
      throw ArgumentError.value(
          rpm, 'rpm', 'requests per minute must be >= 0');
    }
    _requestRates[providerId] = rpm;
  }

  /// The effective spacing for one descriptor's queue keys: the user override
  /// ([_requestRates]) when present, else the descriptor's [ProviderDescriptor
  /// .requestsPerMinute] hint, else null (fall back to the registry-wide
  /// [rateLimiter.minInterval]). Returns null = "use the global default",
  /// [Duration.zero] = spacing explicitly disabled for this provider.
  Duration? _effectiveSpacing(ProviderDescriptor desc) {
    final override = _requestRates[desc.id];
    final rpm = override ?? desc.requestsPerMinute;
    if (rpm == null) return null;
    if (rpm == 0) return Duration.zero;
    return Duration(microseconds:
        (60 * 1000 * 1000 + rpm - 1) ~/ rpm); // ceil to whole µs ≡ ms
  }

  /// Optional overlay catalog. When set, [modelsFor] / [findModel] / [resolve]
  /// consult it first and fall back to the descriptor's compiled `models` map.
  /// Used by `ModelsDevCatalog` to layer a live models.dev registry on top of
  /// the hand-seeded descriptor catalogs. `null` (the default) means the
  /// compiled maps are authoritative.
  ModelCatalog? catalog;

  ProviderRegistry({Map<String, String>? env})
      : _env = env ?? Platform.environment;

  /// Provider ids registered as pools (see [registerPool]) — the ids [build]
  /// must NOT wrap in a [RateLimitedProvider] of their own.
  final Set<String> _poolIds = {};

  /// Register [descriptor] as a provider POOL: a synthetic descriptor whose
  /// builder is expected to call [buildPooled] over its members. A pool
  /// reference (`pool/model`) then resolves through [build] like any other —
  /// the difference is the policy stack: members carry their own per-key
  /// launch slots from [buildPooled], so the pool itself skips the
  /// rate-limit wrap (it has no endpoint+key identity of its own; its queue
  /// key would be degenerate and serialize the WHOLE pool through one slot)
  /// and takes only the metering/retry layers, exactly once.
  void registerPool(ProviderDescriptor descriptor) {
    _poolIds.add(descriptor.id);
    _providers[descriptor.id] = descriptor;
  }

  /// Register a provider descriptor.
  void register(ProviderDescriptor descriptor) {
    _providers[descriptor.id] = descriptor;
  }

  /// Registered provider ids, sorted.
  List<String> get providerIds => _providers.keys.toList()..sort();

  /// All registered descriptors, in registration order. For callers that
  /// need the full set (e.g. the live-models catalog loading every
  /// listable provider at startup).
  Iterable<ProviderDescriptor> get descriptors => _providers.values;

  /// The descriptor for [providerId], or null if unregistered.
  ProviderDescriptor? descriptor(String providerId) => _providers[providerId];

  /// Models offered by [providerId] (empty if unknown). When a [catalog] is
  /// attached, the catalog is consulted first; the compiled `desc.models` map
  /// is the fallback for providers the catalog doesn't know about.
  List<ModelInfo> modelsFor(String providerId) {
    final d = _providers[providerId];
    if (d == null) return const <ModelInfo>[];
    return catalog?.modelsFor(d) ?? d.models.values.toList();
  }

  /// Look up a specific model across all providers by `"provider/model"` or
  /// bare `"model"`. Returns null for an unknown or ambiguous bare match.
  /// Consults [catalog] when set, falling back to the compiled map.
  ModelInfo? findModel(String reference) {
    final ref = ModelReference.parse(reference);
    if (ref.providerId != null) {
      final d = _providers[ref.providerId];
      if (d == null) return null;
      return catalog?.findModel(d, ref.modelId) ?? d.models[ref.modelId];
    }
    ModelInfo? match;
    for (final d in _providers.values) {
      final m = catalog?.findModel(d, ref.modelId) ?? d.models[ref.modelId];
      if (m != null) {
        if (match != null) return null; // ambiguous
        match = m;
      }
    }
    return match;
  }

  /// Resolve a reference to a descriptor + model id. Throws
  /// [ProviderRegistryException] on an unknown provider, an unknown bare model,
  /// or an ambiguous bare model. A prefixed reference (`"provider/model"`)
  /// trusts the prefix; a bare reference scans the [catalog] (when attached)
  /// AND the compiled map for the first match.
  ResolvedModel resolve(String reference) {
    final ref = ModelReference.parse(reference);
    if (ref.providerId != null) {
      final desc = _providers[ref.providerId];
      if (desc == null) {
        throw ProviderRegistryException(
            'Unknown provider "${ref.providerId}". Known: ${providerIds.join(', ')}');
      }
      return ResolvedModel(desc, ref.modelId);
    }
    final matches = <ResolvedModel>[];
    for (final d in _providers.values) {
      final m = catalog?.findModel(d, ref.modelId) ?? d.models[ref.modelId];
      if (m != null) matches.add(ResolvedModel(d, ref.modelId));
    }
    if (matches.isEmpty) {
      throw ProviderRegistryException(
          'Unknown model "$reference" — no registered provider offers it.');
    }
    if (matches.length > 1) {
      throw ProviderRegistryException(
          'Ambiguous model "$reference" — offered by '
          '${matches.map((m) => m.descriptor.id).join(', ')}. '
          'Use "provider/model" to disambiguate.');
    }
    return matches.single;
  }

  /// Resolve [reference] and build the concrete [LlmProvider].
  ///
  /// Auth: if [apiKeyOverride] is given it wins; otherwise the first of the
  /// descriptor's [AuthSource]s whose env var is set supplies the key. A
  /// missing key is an error unless the provider's auth is optional (a `none`
  /// scheme, or no auth sources — e.g. local servers). Overrides are handed
  /// to the builder verbatim: `''` is a real [apiKeyOverride] that skips
  /// environment resolution, so a caller wanting the env fallback passes
  /// null (pinned by the empty-override test in registry_build_test.dart).
  ///
  /// Tuning: [maxTokens], [streamIdleTimeout] and [requestTimeout] land in
  /// the built [ProviderInstance] — registry defaults fill any that are
  /// omitted, on direct builds and on pool members alike (the pool wrapper
  /// itself only takes the session policy stack here; its members' knobs come
  /// through [buildPooled]). They tune the provider; they never change wiring.
  LlmProvider build(
    String reference, {
    String? apiKeyOverride,
    String? baseUrlOverride,
    int? maxTokens,
    Duration? streamIdleTimeout,
    Duration? requestTimeout,
  }) {
    final resolved = resolve(reference);
    // A pool descriptor's builder returns the [PooledProvider] itself, its
    // members already carrying per-key launch slots from [buildPooled]. The
    // pool takes ONLY the session policy stack here — wrapping it in a
    // [RateLimitedProvider] would give it the degenerate queue key of a
    // provider with no endpoint and no key, serializing the whole pool
    // through one slot: the opposite of pooling.
    if (_poolIds.contains(resolved.descriptor.id)) {
      final pool = resolved.descriptor.builder(ProviderInstance(
        apiKey: '',
        model: resolved.modelId,
        baseUrl: resolved.descriptor.defaultBaseUrl,
        maxTokens: maxTokens ?? defaultMaxTokens,
        streamIdleTimeout: streamIdleTimeout ?? defaultStreamIdleTimeout,
        requestTimeout: requestTimeout ?? defaultRequestTimeout,
        authScheme: AuthScheme.none,
      ));
      return _policyStack(pool);
    }
    return _policyStack(_buildLimited(resolved,
        apiKeyOverride: apiKeyOverride,
        baseUrlOverride: baseUrlOverride,
        maxTokens: maxTokens,
        streamIdleTimeout: streamIdleTimeout,
        requestTimeout: requestTimeout));
  }

  /// Build [references] as the members of one [PooledProvider] (see there
  /// for the rotation/failover semantics). Each member goes through
  /// [_buildLimited] — its own launch slot on its own endpoint+key queue —
  /// but NOT the session policy stack: that wraps the POOL, exactly once,
  /// when [build] resolves a pool descriptor. Throws on an empty member list
  /// or a member that is itself a pool. Same override rule as [build]: a
  /// non-null [apiKeyOverride] — `''` included — goes to every member
  /// verbatim; null resolves per member from the environment.
  LlmProvider buildPooled(
    List<String> references, {
    String? apiKeyOverride,
    int? maxTokens,
    Duration? streamIdleTimeout,
    Duration? requestTimeout,
  }) {
    if (references.isEmpty) {
      throw const ProviderRegistryException(
          'a pool needs at least one member reference');
    }
    for (final reference in references) {
      final pid = ModelReference.parse(reference).providerId;
      if (pid != null && _poolIds.contains(pid)) {
        throw ProviderRegistryException(
            'nested pool "$reference" — pools cannot pool pools');
      }
    }
    final members = [
      for (final reference in references)
        _buildLimited(resolve(reference),
            apiKeyOverride: apiKeyOverride,
            maxTokens: maxTokens,
            streamIdleTimeout: streamIdleTimeout,
            requestTimeout: requestTimeout)
    ];
    return PooledProvider(members);
  }

  /// Resolve + auth + build one provider and give it its per-key launch
  /// slot. Everything [build] does below the session policy stack — also the
  /// member path for [buildPooled], which is why it stops here: metering and
  /// retry belong to the pool as a whole, not to each member.
  LlmProvider _buildLimited(
    ResolvedModel resolved, {
    String? apiKeyOverride,
    String? baseUrlOverride,
    int? maxTokens,
    Duration? streamIdleTimeout,
    Duration? requestTimeout,
  }) {
    final desc = resolved.descriptor;
    final AuthScheme scheme;
    final String apiKey;
    if (apiKeyOverride != null) {
      apiKey = apiKeyOverride;
      // An explicit override doesn't carry a scheme; assume the descriptor's
      // primary (the OpenAI-compatible adapter ignores this regardless).
      scheme =
          desc.authSources.isEmpty ? AuthScheme.none : desc.authSources.first.scheme;
    } else {
      final auth = authFor(desc);
      apiKey = auth.key;
      scheme = auth.scheme;
    }
    // No throw on an empty key: providers construct fine with one (they don't
    // validate), and the first-run setup path needs to build a placeholder
    // startup provider before the user has configured credentials. A missing
    // key surfaces as a send-time auth error if a turn is attempted anyway.
    // Forward any per-model extra request-body fields (ModelInfo.extraBody) —
    // the compiled map is the source; the models.dev catalog overlay carries
    // no tina-specific body tweaks.
    final extraBody = desc.models[resolved.modelId]?.extraBody ?? const {};
    final endpoint = baseUrlOverride ?? desc.defaultBaseUrl;
    final built = desc.builder(ProviderInstance(
      apiKey: apiKey,
      model: resolved.modelId,
      baseUrl: endpoint,
      maxTokens: maxTokens ?? defaultMaxTokens,
      streamIdleTimeout: streamIdleTimeout ?? defaultStreamIdleTimeout,
      requestTimeout: requestTimeout ?? defaultRequestTimeout,
      authScheme: scheme,
      extraBody: extraBody,
    ));
    // The policy stack, innermost first:
    //
    //   built → rate limiter → metering → retry
    //
    // * rate limiting innermost so the ledger measures requests that actually
    //   went out, and the spacing/concurrency apply to every wire request;
    //   the queue key is the endpoint+API-key hash (providerQueueKey) — the
    //   hosted per-key identity — not the descriptor id, so two config
    //   providers on one upstream share one queue (and two members of one
    //   pool each keep their own);
    // * metering below retry so each RETRY is measured too (it is a real
    //   request that consumes real tokens);
    // * retry outermost so a re-attempt re-enters the whole stack — it
    //   re-acquires a launch slot instead of bypassing the queue the way the
    //   old transport-internal retry did.
    //
    // Each layer wraps only when enabled, keeping the built provider's
    // concrete type visible (and zero-overhead) in tests and any path that
    // hasn't opted in.
    final key = providerQueueKey(endpoint, apiKey);
    // Per-provider request-rate ceiling: the user's override beats the
    // descriptor's built-in hint, which beats the registry-wide minInterval
    // default. Installed ONCE per queue key (idempotent — repeated builds of
    // the same provider re-install the same value), so a pool of two NIM
    // keys spaces EACH key to NIM's ceiling (aggregate ≈ 2×) instead of one
    // shared queue. Null = no hint/override → the global default applies.
    final spacing = _effectiveSpacing(desc);
    if (spacing != null) rateLimiter.setMinInterval(key, spacing);
    // The wrap decision must read the EFFECTIVE interval for THIS key (the
    // override just installed above, else the registry-wide default) — reading
    // the global alone would leave a descriptor hint unenforced whenever the
    // global limiter is disabled, silently spacing nothing.
    return rateLimiter.minIntervalFor(key) > Duration.zero ||
            rateLimiter.maxConcurrent > 0
        ? RateLimitedProvider(built, rateLimiter, key)
        : built;
  }

  /// The session policy stack above one built provider (or one pool):
  /// metering, then retry. See [_buildLimited] for the layering rationale.
  LlmProvider _policyStack(LlmProvider inner) {
    final metered = decorator == null ? inner : decorator!(inner);
    return maxSendRetries > 0
        ? RetryingProvider(metered, maxRetries: maxSendRetries)
        : metered;
  }

  /// First [AuthSource] whose env var is set in [env] (defaulting to this
  /// registry's env), returning both key and scheme. If none is set, returns an
  /// empty key with the first source's scheme (so the missing-key check still
  /// fires) — or [AuthScheme.none] when the provider declares no sources.
  ///
  /// Public so [Config] can resolve the startup key through the same path
  /// [build] uses — one implementation of the env-var priority scan, not two
  /// copies that can drift. Config passes its own `env` (the registry may have
  /// been constructed with a different one when a caller injects it); [build]
  /// omits it and uses the registry's.
  ({String key, AuthScheme scheme}) authFor(
    ProviderDescriptor desc, {
    Map<String, String>? env,
  }) {
    final e = env ?? _env;
    for (final src in desc.authSources) {
      final v = e[src.envVar];
      if (v != null && v.isNotEmpty) {
        return (key: v, scheme: src.scheme);
      }
    }
    return (
      key: '',
      scheme: desc.authSources.isEmpty
          ? AuthScheme.none
          : desc.authSources.first.scheme,
    );
  }

  /// Whether [desc] can be built without an API key (a `none`-scheme source, or
  /// no auth sources — e.g. local servers). Structural only — it does not
  /// depend on the env map. Public for the same reason as [authFor]: [Config]
  /// applies the identical optional-check at parse time.
  bool isAuthOptional(ProviderDescriptor desc) {
    if (desc.authSources.isEmpty) return true;
    return desc.authSources.any((s) => s.scheme == AuthScheme.none);
  }
}
