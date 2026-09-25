import 'dart:io';

import '../config/user_config.dart';
import 'package:tina_engine/tina_engine.dart';

/// A [ProviderBuilder] that constructs an [AnthropicProvider] from a resolved
/// [ProviderInstance], mapping the registry-resolved [AuthScheme] onto
/// `useBearerAuth` (Bearer for a `*_AUTH_TOKEN`, `x-api-key` otherwise).
///
/// Mirrors the built-in `anthropicDescriptor.builder`
/// (`providers/anthropic_descriptor.dart`) so a user-defined Anthropic-compatible
/// endpoint (z.ai, a proxy, a gateway) gets identical auth behavior with no
/// per-endpoint code.
ProviderBuilder anthropicCompatibleBuilder() => (c) {
  return AnthropicProvider(
    apiKey: c.apiKey,
    useBearerAuth: c.authScheme == AuthScheme.bearerToken,
    model: c.model,
    baseUrl: c.baseUrl,
    maxTokens: c.maxTokens,
    reasoningEffort: c.reasoningEffort,
    streamIdleTimeout: c.streamIdleTimeout,
  );
};

/// Register providers declared in the user config's `[providers.<id>]` blocks.
///
/// Called once from `main()` after the built-ins are registered
/// ([registerBuiltins] / [builtinRegistry]) and **before** [Config.parse],
/// which rejects an unknown default provider id. For each block:
///
/// - `members` set → register a POOL descriptor (see [_registerPool]): the id
///   becomes a round-robin [PooledProvider] over the listed members (bare
///   provider ids, or full `<provider>/<model>` references to mix models),
///   and `<id>/<model>` references rotate across them. Pool blocks skip the
///   `base_url` requirement — the members carry the endpoints and keys.
/// - `wire` unset + **new** id      → register a custom OpenAI-compatible
///   provider (the dominant format for local/third-party servers).
/// - `wire` unset + **built-in** id → leave the built-in alone; the env overlay
///   ([buildEnvOverlay]) already forwards `api_key`/`auth_token`/`base_url` to
///   its native wire format.
/// - `wire` set                     → (re)build the descriptor with that wire
///   format — registering a new id, or replacing a built-in (e.g. repoint `glm`
///   at z.ai's Anthropic-compatible endpoint). A `base_url` is required, since a
///   built-in's default URL targets its *original* wire format. The built-in's
///   model catalog is preserved so bare model references (e.g. `glm-5.2`) still
///   resolve through the overridden descriptor.
///
/// Auth needs no new plumbing: [buildEnvOverlay] turns a block's `api_key` /
/// `auth_token` into `<PREFIX>_API_KEY` / `<PREFIX>_AUTH_TOKEN`, and the
/// descriptor's [AuthSource]s read those same vars via
/// [ProviderRegistry.authFor] — so the key reaches the startup provider
/// (`Config.parse`) and sub-agents (`registry.build`) alike. Pools need none
/// of it: each member resolves its own credential the normal way.
///
/// The pool rotation notice (`tina: pool "<id>" rotates over: …`) fires on the
/// pool's FIRST BUILD, not at attach (#28) — a run that never touches the pool
/// (e.g. an explicit `--model` elsewhere) must not print a member list that
/// reads as "the pool is active". [warn] injects the sink for that notice so
/// tests can observe WHEN it fires; production keeps the default
/// `stderr.writeln`.
void registerConfigProviders(
  ProviderRegistry registry,
  UserConfig userConfig, {
  void Function(String line)? warn,
}) {
  // Explicit type: stderr.writeln's tear-off takes Object?, and without the
  // annotation the ??-inferred type is bare `Function`.
  final void Function(String) warnOut = warn ?? stderr.writeln;
  // Pools register in a second pass so a pool may list config-declared wire
  // providers as members regardless of table order.
  final pools = <MapEntry<String, ProviderConfig>>[];
  for (final entry in userConfig.providers.entries) {
    final id = entry.key;
    final pc = entry.value;
    if (pc.members != null && pc.members!.isNotEmpty) {
      pools.add(entry);
      continue;
    }
    final existing = registry.descriptor(id);
    final wire = _normalizeWire(id, pc.wire, existing);
    final noBaseUrl = pc.baseUrl == null || pc.baseUrl!.isEmpty;

    // No explicit `wire`: the block never builds a custom endpoint. It
    // OVERRIDES an id the registry already serves — a compiled built-in or
    // a models.dev-seeded provider: leave the existing wire, builder and
    // auth alone and merge whatever the block curates (`models`,
    // `max_output`) into the descriptor. /settings writes exactly such
    // blocks for env-credentialed providers (no key, no base_url — both
    // inherited), so skipping them would silently drop the user's model
    // curation and print a bogus "no base_url" warning.
    if (pc.wire == null) {
      if (existing != null) {
        if ((pc.models?.isNotEmpty ?? false) || pc.maxOutput != null) {
          registry.register(
            ProviderDescriptor(
              id: existing.id,
              name: existing.name,
              authSources: existing.authSources,
              defaultBaseUrl: existing.defaultBaseUrl,
              builder: existing.builder,
              models: _configModels(id, pc, existing.models),
              listsRemoteModels: existing.listsRemoteModels,
              requestsPerMinute: existing.requestsPerMinute,
              minRequestIntervalMs:
                  pc.minRequestIntervalMs ?? existing.minRequestIntervalMs,
              maxOutputOverride: pc.maxOutput ?? existing.maxOutputOverride,
            ),
          );
        }
        continue;
      }
      if (noBaseUrl &&
          ((pc.models?.isNotEmpty ?? false) || pc.maxOutput != null)) {
        // Curated id nobody serves: not compiled-in, not seeded from
        // models.dev (that seed runs before this pass), and no base_url to
        // build a custom provider from. The list is inert — warn plainly
        // instead of the misleading no-base_url line the old path printed.
        warnOut(
          'warning: [providers.$id] curates models but no provider '
          'serves "$id" yet (no base_url, not a built-in); the list '
          'applies once the provider is registered.',
        );
        continue;
      }
      // else: a dangling custom provider (no wire, no base_url, nothing
      // curated) — fall through to the warning below.
    }

    if (noBaseUrl) {
      stderr.writeln(
        'warning: [providers.$id] defines a custom provider but has '
        'no base_url; skipping.',
      );
      continue;
    }
    final catalog = _configModels(id, pc, existing?.models ?? const {});
    // `wire` is non-null here: every pc.wire==null case above continued
    // (merge, warn-and-continue, or fallthrough — the last implies
    // existing==null, for which _normalizeWire returns 'openai').
    _registerCustom(registry, id, pc, wire!, catalog, baseUrl: pc.baseUrl);
  }
  for (final entry in pools) {
    _registerPool(registry, entry.key, entry.value, userConfig, warnOut);
  }
}

/// The descriptor catalog for a custom provider: the provider's own
/// [ProviderDescriptor.models] (a built-in being re-pointed keeps its
/// compiled entries) UNION any `models = [...]` the config declared — the
/// common case, since a user-defined id has no compiled catalog and the list
/// is its whole picker presence (`/spawn`, `/model`). A declared entry
/// REPLACES a same-id compiled entry, so the user's display name wins over
/// the compiled metadata.
///
/// Declared ids get the live-catalog defaults (128k context / unknown output) —
/// the same shape [LiveModelsCatalog] synthesizes for ids it discovers from
/// a remote `GET /v1/models`.
Map<String, ModelInfo> _configModels(
  String id,
  ProviderConfig pc,
  Map<String, ModelInfo> base,
) {
  final catalog = Map<String, ModelInfo>.of(base);
  for (final spec in (pc.models ?? const <ProviderModelSpec>[])) {
    final previous = base[spec.id];
    catalog[spec.id] = ModelInfo(
      id: spec.id,
      name: spec.name ?? spec.id,
      contextWindow: previous?.contextWindow ?? 131072,
      maxOutput: previous?.maxOutput,
      supportsTools: previous?.supportsTools ?? true,
      supportsVision: previous?.supportsVision ?? false,
      supportsCaching: previous?.supportsCaching ?? false,
      extraBody: previous?.extraBody ?? const {},
    );
  }
  return catalog;
}

/// Register `id` as a pool over `pc.members`: a synthetic descriptor whose
/// builder resolves every member through [ProviderRegistry.buildPooled]. Its
/// model catalog is the UNION of the members' (so the model picker lists
/// everything any member serves), and its auth is empty — credentials live on
/// the members.
///
/// A member entry is either a bare provider id (`"nim"` — the model comes
/// from the pool reference `<pool>/<model>`, so every bare member must serve
/// that same model id) or a FULL reference (`"nim/meta/muse-glimmer-30b"`,
/// `"hetzner/Qwen3.8-27B"` — the member is pinned to that model, letting one
/// pool mix models AND providers: two 40-RPM endpoints serving different
/// models still double throughput). A `/model` swap fans out to every member
/// verbatim, so a mixed-model pool should not be `/model`-swapped at runtime.
///
/// Rate limits compose without new knobs: the registry's shared limiter queues
/// per endpoint+API-key, so each member is spaced by `[limits]
/// min_request_interval_ms` against ITSELF (three members at 1500 ms ≈ 40 RPM
/// each ≈ 120 RPM aggregate) while `[limits] requests_per_minute` remains the
/// session-wide ceiling — it must be raised to the sum (or 0) or it
/// bottlenecks the pool at one member's cap.
void _registerPool(
  ProviderRegistry registry,
  String id,
  ProviderConfig pc,
  UserConfig config,
  void Function(String line) warnOut,
) {
  final entries = pc.members!;
  // The provider id of a full reference is the text before the first slash
  // (model ids themselves may contain slashes: `meta/muse-glimmer-30b`).
  final memberProviderIds = [
    for (final entry in entries)
      ModelReference.parse(entry).providerId ?? entry,
  ];
  if (memberProviderIds.contains(id)) {
    stderr.writeln(
      'warning: [providers.$id] lists itself as a pool member; '
      'skipping.',
    );
    return;
  }
  for (final memberId in memberProviderIds) {
    if (registry.descriptor(memberId) == null) {
      stderr.writeln(
        'warning: [providers.$id] pools unknown provider '
        '"$memberId"; skipping the pool.',
      );
      return;
    }
    final memberConfig = config.providers[memberId];
    if (memberConfig?.members != null && memberConfig!.members!.isNotEmpty) {
      stderr.writeln(
        'warning: [providers.$id] pools "$memberId", which is '
        'itself a pool (nesting is not supported); skipping.',
      );
      return;
    }
  }

  final catalog = <String, ModelInfo>{};
  for (final entry in entries) {
    final ref = ModelReference.parse(entry);
    if (ref.providerId == null) {
      // Bare id: the member serves whatever `<pool>/<model>` says — surface
      // its whole catalog.
      for (final m in registry.modelsFor(entry)) {
        catalog[m.id] = m;
      }
    } else {
      // Full reference: only that model. Null when the provider's compiled
      // catalog lacks it (e.g. a newly-added id ahead of a release) — the
      // pool still serves it, it just isn't listed until the catalog catches
      // up.
      final m = registry.findModel(entry);
      if (m != null) catalog[m.id] = m;
    }
  }
  // Warn-once flag, captured by the builder below.
  var warned = false;
  registry.registerPool(
    ProviderDescriptor(
      id: id,
      name: pc.name ?? _titleCase(id),
      authSources: const [],
      defaultBaseUrl: '',
      // The instance's model id is the part after `<pool>/`. Bare members are
      // resolved as `<member>/<that model>`; full references are pinned and
      // ignore it.
      builder: (c) {
        // Warn on FIRST BUILD, not at attach (#28): a run that never touches the
        // pool (e.g. an explicit `--model` elsewhere) must not print a member
        // list that reads as "the pool is active".
        if (!warned) {
          warned = true;
          warnOut(
            'tina: pool "$id" rotates over: ${entries.join(', ')} '
            '(per-member spacing via [limits] min_request_interval_ms or '
            '[providers.<id>] requests_per_minute; raise the limits to the '
            'sum or the session cap bottlenecks the pool)',
          );
        }
        return registry.buildPooled(
          [
            for (final entry in entries)
              ModelReference.parse(entry).providerId == null
                  ? '$entry/${c.model}'
                  : entry,
          ],
          maxTokens: c.maxTokens,
          reasoningEffort: c.reasoningEffort,
          streamIdleTimeout: c.streamIdleTimeout,
          requestTimeout: c.requestTimeout,
        );
      },
      models: catalog,
      maxOutputOverride: pc.maxOutput,
    ),
  );
}

/// Resolves the effective wire format for a config block, or null when the block
/// should be ignored (a built-in id with no explicit `wire`).
String? _normalizeWire(
  String id,
  String? declared,
  ProviderDescriptor? existing,
) {
  if (declared == null) {
    // No wire declared: a new id defaults to OpenAI-compatible; a built-in is
    // left to the env-overlay path.
    return existing == null ? 'openai' : null;
  }
  if (declared != 'anthropic' && declared != 'openai') {
    stderr.writeln(
      'warning: [providers.$id] wire="$declared" (expected '
      '"anthropic" or "openai"); defaulting to "openai".',
    );
    return 'openai';
  }
  return declared;
}

void _registerCustom(
  ProviderRegistry registry,
  String id,
  ProviderConfig pc,
  String wire,
  Map<String, ModelInfo> catalog, {
  required String? baseUrl,
}) {
  final existing = registry.descriptor(id);
  final prefix = id.toUpperCase();
  final displayName = pc.name ?? existing?.name ?? _titleCase(id);

  final List<AuthSource> authSources;
  final ProviderBuilder builder;
  if (wire == 'anthropic') {
    // bearer for *_AUTH_TOKEN, x-api-key for *_API_KEY — same shape as the
    // built-in anthropic descriptor.
    authSources = [
      AuthSource('${prefix}_AUTH_TOKEN', AuthScheme.bearerToken),
      AuthSource('${prefix}_API_KEY', AuthScheme.apiKeyHeader),
    ];
    builder = anthropicCompatibleBuilder();
  } else {
    // OpenAI-compatible: both credential kinds go on the wire as Bearer; the
    // adapter ignores the scheme.
    authSources = [
      AuthSource('${prefix}_API_KEY', AuthScheme.bearerToken),
      AuthSource('${prefix}_AUTH_TOKEN', AuthScheme.bearerToken),
    ];
    builder = openAiCompatibleBuilder(displayName);
  }

  registry.register(
    ProviderDescriptor(
      id: id,
      name: displayName,
      authSources: authSources,
      defaultBaseUrl: baseUrl ?? existing?.defaultBaseUrl ?? '',
      builder: builder,
      models: catalog,
      maxOutputOverride: pc.maxOutput,
    ),
  );
}

String _titleCase(String id) {
  if (id.isEmpty) return id;
  return id[0].toUpperCase() + id.substring(1);
}

/// Wire the user config's rate-limit knobs into [registry]'s shared limiter —
/// the composition-root equivalent of the startup block in `bin/tina.dart`,
/// extracted so `/settings` can re-run it after a save (apply-now) instead of
/// telling the user to restart.
///
/// Idempotent: every call re-installs the same values from [userConfig], so
/// startup and every settings write converge on the same limiter state.
/// Returns the config-smell diagnostics the startup path used to write
/// straight to stderr (both interval and RPM set for one provider); the caller
/// chooses the channel — stderr at startup, an in-chat warning from
/// `/settings`.
///
/// Per-provider spacing overrides reach queues that already BUILT via the
/// closing [ProviderRegistry.reapplyRequestIntervals] — the wrap decision
/// reads the override at acquire time, so a reinstall lands without restart.
/// (The global knobs — `[limits] min_request_interval_ms`,
/// `max_concurrent_requests` — are plain fields on the limiter and are always
/// live the moment they're assigned.)
List<String> applyRateLimitConfig(
  ProviderRegistry registry,
  UserConfig userConfig,
) {
  final globalIntervalMs = userConfig.limits?.minRequestIntervalMs;
  registry.rateLimiter.minInterval = globalIntervalMs == null
      ? defaultMinRequestInterval
      : Duration(milliseconds: globalIntervalMs);
  registry.rateLimiter.maxConcurrent =
      userConfig.limits?.maxConcurrentRequests ?? defaultMaxConcurrentRequests;
  // Per-provider request-rate ceilings from `[providers.<id>]
  // requests_per_minute` / `min_request_interval_ms`: the interval form wins
  // over the RPM form (see effectiveSpacingMs in the engine's
  // provider_rate_limit.dart); warn when both
  // are set so the config smell is visible instead of silently resolved.
  // The on-disk provider map is the source of truth: drop every in-memory
  // override FIRST (a setting DELETED from the config must not linger in the
  // registry), then reinstall the ones the config still declares, then push
  // the recomputed values onto the live queues. Order matters — clearing
  // after the install loop would erase exactly what it just installed.
  registry.clearRequestOverrides();
  final warnings = <String>[];
  for (final entry in userConfig.providers.entries) {
    final rpm = entry.value.requestsPerMinute;
    final intervalMs = entry.value.minRequestIntervalMs;
    if (intervalMs != null && rpm != null) {
      warnings.add(
        'warning: [providers.${entry.key}] sets both '
        'min_request_interval_ms and requests_per_minute; the interval '
        'wins.',
      );
    }
    if (rpm != null) registry.setRequestRate(entry.key, rpm);
    if (intervalMs != null) registry.setRequestInterval(entry.key, intervalMs);
  }
  registry.reapplyRequestIntervals();
  return warnings;
}
