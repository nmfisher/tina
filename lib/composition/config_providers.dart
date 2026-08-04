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
/// (`Config.parse`) and sub-agents (`registry.build`) alike.
void registerConfigProviders(
    ProviderRegistry registry, UserConfig userConfig) {
  for (final entry in userConfig.providers.entries) {
    final id = entry.key;
    final pc = entry.value;
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
