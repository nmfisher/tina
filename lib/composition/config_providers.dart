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
ProviderBuilder anthropicCompatibleBuilder() => (c) => AnthropicProvider(
      apiKey: c.apiKey,
      useBearerAuth: c.authScheme == AuthScheme.bearerToken,
      model: c.model,
      baseUrl: c.baseUrl,
      maxTokens: c.maxTokens,
      streamIdleTimeout: c.streamIdleTimeout,
    );

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
    ProviderRegistry registry, UserConfig userConfig,
    {void Function(String line)? warn}) {
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

    // null wire = built-in id with no explicit wire → leave to the env overlay.
    if (wire == null) continue;

    if (pc.baseUrl == null || pc.baseUrl!.isEmpty) {
      stderr.writeln('warning: [providers.$id] defines a custom provider but has '
          'no base_url; skipping.');
      continue;
    }
    final catalog = existing?.models ?? const <String, ModelInfo>{};
    _registerCustom(registry, id, pc, wire, catalog, baseUrl: pc.baseUrl);
  }
  for (final entry in pools) {
    _registerPool(registry, entry.key, entry.value, userConfig, warnOut);
  }
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
void _registerPool(ProviderRegistry registry, String id, ProviderConfig pc,
    UserConfig config, void Function(String line) warnOut) {
  final entries = pc.members!;
  // The provider id of a full reference is the text before the first slash
  // (model ids themselves may contain slashes: `meta/muse-glimmer-30b`).
  final memberProviderIds = [
    for (final entry in entries) ModelReference.parse(entry).providerId ?? entry
  ];
  if (memberProviderIds.contains(id)) {
    stderr.writeln('warning: [providers.$id] lists itself as a pool member; '
        'skipping.');
    return;
  }
  for (final memberId in memberProviderIds) {
    if (registry.descriptor(memberId) == null) {
      stderr.writeln('warning: [providers.$id] pools unknown provider '
          '"$memberId"; skipping the pool.');
      return;
    }
    final memberConfig = config.providers[memberId];
    if (memberConfig?.members != null && memberConfig!.members!.isNotEmpty) {
      stderr.writeln('warning: [providers.$id] pools "$memberId", which is '
          'itself a pool (nesting is not supported); skipping.');
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
  registry.registerPool(ProviderDescriptor(
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
        warnOut('tina: pool "$id" rotates over: ${entries.join(', ')} '
            '(per-member spacing via [limits] min_request_interval_ms or '
            '[providers.<id>] requests_per_minute; raise the limits to the '
            'sum or the session cap bottlenecks the pool)');
      }
      return registry.buildPooled(
        [
          for (final entry in entries)
            ModelReference.parse(entry).providerId == null
                ? '$entry/${c.model}'
                : entry
        ],
        maxTokens: c.maxTokens,
        streamIdleTimeout: c.streamIdleTimeout,
        requestTimeout: c.requestTimeout,
      );
    },
    models: catalog,
  ));
}

/// Resolves the effective wire format for a config block, or null when the block
/// should be ignored (a built-in id with no explicit `wire`).
String? _normalizeWire(
    String id, String? declared, ProviderDescriptor? existing) {
  if (declared == null) {
    // No wire declared: a new id defaults to OpenAI-compatible; a built-in is
    // left to the env-overlay path.
    return existing == null ? 'openai' : null;
  }
  if (declared != 'anthropic' && declared != 'openai') {
    stderr.writeln('warning: [providers.$id] wire="$declared" (expected '
        '"anthropic" or "openai"); defaulting to "openai".');
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

  registry.register(ProviderDescriptor(
    id: id,
    name: displayName,
    authSources: authSources,
    defaultBaseUrl: baseUrl ?? existing?.defaultBaseUrl ?? '',
    builder: builder,
    models: catalog,
  ));
}

String _titleCase(String id) {
  if (id.isEmpty) return id;
  return id[0].toUpperCase() + id.substring(1);
}
