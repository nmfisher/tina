import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:toml/toml.dart';

import 'package:tina_engine/tina_engine.dart';
import 'package:tina_console/tina_console.dart';

/// The config schema version this build understands. The file declares its
/// version with a top-level `version = N`; [loadUserConfig] refuses (with a
/// warning) anything that doesn't match, so a future-old or future-new file is
/// ignored wholesale rather than mis-parsed. When the schema next changes,
/// bump this and add a migrator at the version check in [loadUserConfig].
const int kCurrentConfigVersion = 1;

/// Top-level keys [loadUserConfig] recognizes. Anything else is reported as a
/// likely typo (e.g. `[tier]` for `[tiers]`) rather than silently ignored.
const _knownTopLevelKeys = {'version', 'default', 'tiers', 'providers', 'limits', 'prompts', 'theme', 'trust'};
const _knownDefaultKeys = {'provider', 'model', 'workflow'};
const _knownProviderKeys = {'api_key', 'auth_token', 'base_url', 'wire', 'name', 'disabled_models'};
const _knownPromptKeys = {'identity'};
const _knownLimitsKeys = {
  'max_global_tokens',
  'max_sub_agent_tokens',
  'requests_per_minute',
  'max_session_tokens',
  'max_turn_tokens',
  'max_request_tokens',
};

/// Per-provider overrides from a `[providers.<id>]` table in the user config.
/// Null fields are ignored by [buildEnvOverlay].
class ProviderConfig {
  /// `api_key` → `<PREFIX>_API_KEY` (e.g. `ANTHROPIC_API_KEY`, x-api-key).
  final String? apiKey;

  /// `auth_token` → `<PREFIX>_AUTH_TOKEN` (bearer; e.g. Anthropic's
  /// `ANTHROPIC_AUTH_TOKEN`). Alternative to [apiKey] for providers that take
  /// both.
  final String? authToken;

  /// `base_url` → `<PREFIX>_BASE_URL`. Overrides the descriptor's default.
  final String? baseUrl;

  /// Selects the wire format for this provider: `"anthropic"` (Anthropic
  /// `/v1/messages`) or `"openai"` (OpenAI `/chat/completions`). Setting it has
  /// two effects, depending on whether `<id>` is a built-in:
  ///
  /// - **New id** (not a built-in): registers a custom provider descriptor that
  ///   speaks this wire format. Defaults to `"openai"` when unset.
  /// - **Built-in id**: replaces the built-in descriptor with one using this wire
  ///   format (e.g. repoint `glm` at z.ai's Anthropic-compatible endpoint). A
  ///   `base_url` is required when `wire` is set, since the built-in's default
  ///   URL is for its original wire format. The built-in's model catalog is
  ///   preserved so bare model references (e.g. `glm-5.2`) still resolve.
  ///
  /// Unset + built-in id leaves the built-in untouched (the env overlay already
  /// handles key/base_url overrides for the native wire format).
  final String? wire;

  /// Optional display name used in error messages for a custom provider
  /// (defaults to a title-cased id). Ignored when overriding a built-in unless
  /// set.
  final String? name;

  /// Model ids the user has explicitly disabled for `/spawn` within this
  /// provider. When empty/null all models are available. Persisted so the
  /// uncheck state survives restarts.
  final Set<String>? disabledModels;

  const ProviderConfig({
    this.apiKey,
    this.authToken,
    this.baseUrl,
    this.wire,
    this.name,
    this.disabledModels,
  });

  factory ProviderConfig.fromMap(Map<String, dynamic> m) {
    Set<String>? disabled;
    final raw = m['disabled_models'];
    if (raw is List) {
      final s = raw.whereType<String>().toSet();
      if (s.isNotEmpty) disabled = s;
    }
    return ProviderConfig(
      apiKey: m['api_key'] as String?,
      authToken: m['auth_token'] as String?,
      baseUrl: m['base_url'] as String?,
      wire: m['wire'] as String?,
      name: m['name'] as String?,
      disabledModels: disabled,
    );
  }

  /// Value equality — every field is an immutable scalar or set, so two configs
  /// compare equal when their fields match (used to detect an edit that changed
  /// nothing, `disabledModels` compared as sets).
  @override
  bool operator ==(Object other) =>
      other is ProviderConfig &&
      apiKey == other.apiKey &&
      authToken == other.authToken &&
      baseUrl == other.baseUrl &&
      wire == other.wire &&
      name == other.name &&
      _setsEqual(disabledModels, other.disabledModels);

  @override
  int get hashCode => Object.hash(
      apiKey, authToken, baseUrl, wire, name, Set.of(disabledModels ?? const {}));

  static bool _setsEqual(Set<String>? a, Set<String>? b) {
    if (a == null && b == null) return true;
    if (a == null || b == null) return false;
    if (a.length != b.length) return false;
    return a.containsAll(b);
  }
}

/// Spend / rate-limit overrides from a `[limits]` table in the user config. Null
/// fields mean "not set in the file" — [Config.parse] falls back to its built-in
/// default, so omitting the whole table reproduces the shipped defaults.
class LimitsConfig {
  /// Global token ceiling across every agent this app session (0 = unbounded).
  final int? maxGlobalTokens;

  /// Per sub-agent token ceiling (0 = unbounded). Sub-agents otherwise run
  /// uncapped.
  final int? maxSubAgentTokens;

  /// Max nesting depth for sub-agent delegation (null = built-in default).
  final int? maxSubAgentDepth;

  /// Max agents allowed to run concurrently (null = built-in default).
  final int? maxSubAgentConcurrency;

  /// Outbound requests-per-minute cap shared by all agents (0 = disabled).
  final int? requestsPerMinute;

  /// Per-turn / per-session / per-request-input caps on the MAIN agent's
  /// [TokenBudget] (0 = that cap disabled). These mirror the `--max-*-tokens`
  /// flags so the whole token-limit surface is configurable from `/settings`.
  final int? maxTurnTokens;
  final int? maxSessionTokens;
  final int? maxRequestTokens;

  const LimitsConfig({
    this.maxGlobalTokens,
    this.maxSubAgentTokens,
    this.maxSubAgentDepth,
    this.maxSubAgentConcurrency,
    this.requestsPerMinute,
    this.maxTurnTokens,
    this.maxSessionTokens,
    this.maxRequestTokens,
  });

  factory LimitsConfig.fromMap(Map<String, dynamic> m) => LimitsConfig(
        maxGlobalTokens: m['max_global_tokens'] as int?,
        maxSubAgentTokens: m['max_sub_agent_tokens'] as int?,
        maxSubAgentDepth: m['max_sub_agent_depth'] as int?,
        maxSubAgentConcurrency: m['max_sub_agent_concurrency'] as int?,
        requestsPerMinute: m['requests_per_minute'] as int?,
        maxTurnTokens: m['max_turn_tokens'] as int?,
        maxSessionTokens: m['max_session_tokens'] as int?,
        maxRequestTokens: m['max_request_tokens'] as int?,
      );

  bool get isEmpty =>
      maxGlobalTokens == null &&
      maxSubAgentTokens == null &&
      maxSubAgentDepth == null &&
      maxSubAgentConcurrency == null &&
      requestsPerMinute == null &&
      maxTurnTokens == null &&
      maxSessionTokens == null &&
      maxRequestTokens == null;

  /// Value equality over the eight nullable limits (used to detect an edit that
  /// changed nothing).
  @override
  bool operator ==(Object other) =>
      other is LimitsConfig &&
      maxGlobalTokens == other.maxGlobalTokens &&
      maxSubAgentTokens == other.maxSubAgentTokens &&
      maxSubAgentDepth == other.maxSubAgentDepth &&
      maxSubAgentConcurrency == other.maxSubAgentConcurrency &&
      requestsPerMinute == other.requestsPerMinute &&
      maxTurnTokens == other.maxTurnTokens &&
      maxSessionTokens == other.maxSessionTokens &&
      maxRequestTokens == other.maxRequestTokens;

  @override
  int get hashCode => Object.hash(
      maxGlobalTokens,
      maxSubAgentTokens,
      maxSubAgentDepth,
      maxSubAgentConcurrency,
      requestsPerMinute,
      maxTurnTokens,
      maxSessionTokens,
      maxRequestTokens);
}

/// The parsed `~/.tina/config`. [defaultProvider]/[defaultModel]/[tiers] flow
/// into `Config.parse` as a precedence layer (CLI > file > env); [providers]
/// becomes a synthetic env overlay via [buildEnvOverlay] so its keys reach every
/// agent — the startup provider AND sub-agents, which resolve keys through the
/// registry's env scan rather than the startup override.
class UserConfig {
  final String? defaultProvider;
  final String? defaultModel;

  /// DOT workflow to route every normal turn through, from `[default] workflow`.
  /// `"none"` explicitly disables the presence-based `default.dot` routing; any
  /// other value names a workflow in `~/.tina/workflows`; null/absent means
  /// "use `default.dot` when it exists".
  final String? defaultWorkflow;

  final Map<String, String> tiers;
  final Map<String, ProviderConfig> providers;
  final LimitsConfig? limits;

  /// Terminal color overrides from the `[theme]` table. Null means "use the
  /// shipped default theme".
  final Theme? theme;

  /// Named theme variant from `[theme] variant`. Null when absent or when
  /// per-key overrides are present. One of `"light"` or `"dark"`.
  final String? themeVariant;

  /// Per-role system-prompt identity overrides from a `[prompts.<role>]` table
  /// (`identity = "..."`). role → identity prose. Flows into `Config.parse` as
  /// [Config.promptOverrides]; an empty/absent entry means "use the built-in
  /// default identity for that role".
  final Map<String, String> prompts;

  /// Default project-trust behavior from `[trust] default` (`ask`/`always`/
  /// `never`). Null when absent → `ask`. Flows into `Config.parse` as
  /// [Config.trustDefault].
  final String? trustDefault;

  /// Schema version the file declared (defaults to [kCurrentConfigVersion] when
  /// absent). [loadUserConfig] only returns a config whose version matches.
  final int version;

  const UserConfig({
    this.defaultProvider,
    this.defaultModel,
    this.defaultWorkflow,
    this.tiers = const {},
    this.providers = const {},
    this.limits,
    this.theme,
    this.themeVariant,
    this.prompts = const {},
    this.trustDefault,
    this.version = kCurrentConfigVersion,
  });

  static const empty = UserConfig();

  bool get isEmpty =>
      defaultProvider == null &&
      defaultModel == null &&
      defaultWorkflow == null &&
      tiers.isEmpty &&
      providers.isEmpty &&
      (limits == null || limits!.isEmpty) &&
      theme == null &&
      prompts.isEmpty &&
      trustDefault == null;

  /// Builds a [UserConfig] from the `toml` package's `toMap()` output. Unknown
  /// keys are ignored; non-string tier values are skipped (defensive).
  factory UserConfig.fromMap(Map<String, dynamic> m) {
    final def = (m['default'] as Map?)?.cast<String, dynamic>();
    final tiersRaw = (m['tiers'] as Map?)?.cast<String, dynamic>();
    final providersRaw = (m['providers'] as Map?)?.cast<String, dynamic>();
    final limitsRaw = (m['limits'] as Map?)?.cast<String, dynamic>();
    final themeRaw = (m['theme'] as Map?)?.cast<String, dynamic>();
    final themeVariant = themeRaw?['variant'] as String?;
    final theme =
        themeRaw == null ? null : Theme.fromMap(themeRaw);
    final promptsRaw = (m['prompts'] as Map?)?.cast<String, dynamic>();
    final trustRaw = (m['trust'] as Map?)?.cast<String, dynamic>();
    final trustDefault = trustRaw?['default'] as String?;
    final tiers = <String, String>{};
    for (final e in (tiersRaw ?? const <String, dynamic>{}).entries) {
      if (e.value is String) tiers[e.key] = e.value as String;
    }
    final providers = <String, ProviderConfig>{};
    for (final e in (providersRaw ?? const <String, dynamic>{}).entries) {
      if (e.value is Map) {
        providers[e.key] =
            ProviderConfig.fromMap((e.value as Map).cast<String, dynamic>());
      }
    }
    // [prompts.<role>] tables: each holds an `identity` string. A role whose
    // identity is absent or empty is skipped (treated as "use the default").
    final prompts = <String, String>{};
    for (final e in (promptsRaw ?? const <String, dynamic>{}).entries) {
      if (e.value is Map) {
        final id = (e.value as Map).cast<String, dynamic>()['identity'];
        if (id is String && id.isNotEmpty) prompts[e.key] = id;
      }
    }
    return UserConfig(
      defaultProvider: def?['provider'] as String?,
      defaultModel: def?['model'] as String?,
      defaultWorkflow: def?['workflow'] as String?,
      tiers: tiers,
      providers: providers,
      limits: limitsRaw == null ? null : LimitsConfig.fromMap(limitsRaw),
      theme: theme,
      themeVariant: themeVariant,
      prompts: prompts,
      trustDefault: trustDefault,
      version: (m['version'] as int?) ?? kCurrentConfigVersion,
    );
  }
}

/// The config file path: `<tinaDir>/config` ([tinaDir] injectable for tests).
File userConfigFile(Map<String, String> env, {Directory? tinaDir}) =>
    File(p.join((tinaDir ?? tinaDirFromEnv(env)).path, 'config'));

/// Load and parse `~/.tina/config`. Recovery policy (a bad config never
/// blocks startup — flags/env still work):
/// - missing file → [UserConfig.empty], silently.
/// - parse error or wrong-shape value → warn + empty (the file is left intact
///   on disk for the user to fix).
/// - unsupported `version` → warn + empty. (When a v2 schema lands, run a
///   migrator here instead of returning empty.)
/// - unknown keys / typos → warn per key, but still load the valid parts.
///
/// [tinaDir] is injectable for tests.
UserConfig loadUserConfig({
  required Map<String, String> env,
  Directory? tinaDir,
}) {
  final file = userConfigFile(env, tinaDir: tinaDir);
  if (!file.existsSync()) return UserConfig.empty;
  try {
    final map = TomlDocument.parse(file.readAsStringSync()).toMap();
    final version = (map['version'] as int?) ?? kCurrentConfigVersion;
    if (version != kCurrentConfigVersion) {
      // Future: if version < current, migrate(map, version) here; if version >
      // current, the user downgraded tina. Either way, refuse for now.
      stderr.writeln('warning: ${file.path} is config version $version, but '
          'this tina supports version $kCurrentConfigVersion; ignoring it. '
          'Run --init-config for a fresh template.');
      return UserConfig.empty;
    }
    _warnUnknownKeys(map, file.path);
    return UserConfig.fromMap(map);
  } catch (e) {
    stderr.writeln('warning: failed to parse ${file.path}: $e');
    return UserConfig.empty;
  }
}

/// Warn about keys we don't recognize — typos like `[tier]` or
/// `[providers.anthropic] key = ...` would otherwise be silently ignored,
/// making the config appear to take effect while doing nothing. Warns only;
/// the caller still loads the recognized sections.
void _warnUnknownKeys(Map<String, dynamic> m, String path) {
  void warn(String key, Set<String> known) => stderr.writeln(
      'warning: $path: unknown key "$key" (known: ${known.join(', ')}).');
  for (final k in m.keys) {
    if (!_knownTopLevelKeys.contains(k)) warn(k, _knownTopLevelKeys);
  }
  final def = m['default'];
  if (def is Map) {
    for (final k in def.keys) {
      if (!_knownDefaultKeys.contains(k)) warn('default.$k', _knownDefaultKeys);
    }
  }
  final providers = m['providers'];
  if (providers is Map) {
    for (final pe in providers.entries) {
      if (pe.value is Map) {
        for (final k in (pe.value as Map).keys) {
          if (!_knownProviderKeys.contains(k)) {
            warn('providers.${pe.key}.$k', _knownProviderKeys);
          }
        }
      }
    }
  }
  final limits = m['limits'];
  if (limits is Map) {
    for (final k in limits.keys) {
      if (!_knownLimitsKeys.contains(k)) warn('limits.$k', _knownLimitsKeys);
    }
  }
  final prompts = m['prompts'];
  if (prompts is Map) {
    for (final pe in prompts.entries) {
      if (pe.value is Map) {
        for (final k in (pe.value as Map).keys) {
          if (!_knownPromptKeys.contains(k)) {
            warn('prompts.${pe.key}.$k', _knownPromptKeys);
          }
        }
      }
    }
  }
}

/// Translate the `[providers.<id>]` block into a synthetic env overlay: each
/// set field becomes `<PREFIX>_API_KEY` / `<PREFIX>_AUTH_TOKEN` /
/// `<PREFIX>_BASE_URL` (PREFIX = provider id uppercased). The caller merges this
/// over the real env with the overlay winning, so the file's keys reach
/// `ProviderRegistry.authFor` for every agent and `<PREFIX>_BASE_URL` reaches
/// Config.parse's existing base-url read.
Map<String, String> buildEnvOverlay(UserConfig config) {
  final out = <String, String>{};
  for (final entry in config.providers.entries) {
    // Some providers' env var names don't match the simple prefix pattern
    // (e.g. provider id "nim" → env var "NVIDIA_API_KEY"). Use the override
    // map when one exists, otherwise uppercase the provider id.
    const overrides = <String, String>{
      'nim': 'NVIDIA',
      'grok': 'XAI',
      'qwen': 'DASHSCOPE',
    };
    final prefix = overrides[entry.key] ?? entry.key.toUpperCase();
    final pc = entry.value;
    if (pc.apiKey != null) out['${prefix}_API_KEY'] = pc.apiKey!;
    if (pc.authToken != null) out['${prefix}_AUTH_TOKEN'] = pc.authToken!;
    if (pc.baseUrl != null) out['${prefix}_BASE_URL'] = pc.baseUrl!;
  }
  return out;
}

/// Write a commented TOML template to `<tinaDir>/config` (chmod 600) so a new
/// user can bootstrap the persistent config. Creates the directory if needed.
/// Prints the path to stdout. [tinaDir] is injectable for tests.
void writeConfigTemplate({
  required Map<String, String> env,
  Directory? tinaDir,
}) {
  final dir = tinaDir ?? tinaDirFromEnv(env);
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final file = File(p.join(dir.path, 'config'));
  file.writeAsStringSync(_kConfigTemplate);
  // Best-effort 0600 — the file may hold API keys. No-op on non-Unix / if
  // chmod is unavailable; never let a perm failure abort the write.
  try {
    Process.runSync('chmod', ['600', file.path]);
  } catch (_) {}
  stdout.writeln('wrote ${file.path}');
}

/// Serialize [config] to a TOML string via the `toml` package's encoder
/// (`TomlDocument.fromMap(...).toString()`), so string escaping — API keys with
/// special characters — is handled correctly rather than hand-rolled. Empty
/// sections are omitted. Round-trips with [UserConfig.fromMap].
String userConfigToToml(UserConfig config) {
  final map = <String, dynamic>{
    'version': config.version,
    if (config.defaultProvider != null ||
        config.defaultModel != null ||
        config.defaultWorkflow != null)
      'default': {
        if (config.defaultProvider != null) 'provider': config.defaultProvider,
        if (config.defaultModel != null) 'model': config.defaultModel,
        if (config.defaultWorkflow != null)
          'workflow': config.defaultWorkflow,
      },
    if (config.tiers.isNotEmpty) 'tiers': config.tiers,
    if (config.providers.isNotEmpty)
      'providers': {
        for (final e in config.providers.entries)
          e.key: {
            if (e.value.apiKey != null) 'api_key': e.value.apiKey,
            if (e.value.authToken != null) 'auth_token': e.value.authToken,
            if (e.value.baseUrl != null) 'base_url': e.value.baseUrl,
            if (e.value.wire != null) 'wire': e.value.wire,
            if (e.value.name != null) 'name': e.value.name,
            if (e.value.disabledModels != null && e.value.disabledModels!.isNotEmpty)
              'disabled_models': e.value.disabledModels!.toList(),
          },
      },
    if (config.limits != null && !config.limits!.isEmpty)
      'limits': {
        if (config.limits!.maxGlobalTokens != null)
          'max_global_tokens': config.limits!.maxGlobalTokens,
        if (config.limits!.maxSubAgentTokens != null)
          'max_sub_agent_tokens': config.limits!.maxSubAgentTokens,
        if (config.limits!.maxSubAgentDepth != null)
          'max_sub_agent_depth': config.limits!.maxSubAgentDepth,
        if (config.limits!.maxSubAgentConcurrency != null)
          'max_sub_agent_concurrency': config.limits!.maxSubAgentConcurrency,
        if (config.limits!.requestsPerMinute != null)
          'requests_per_minute': config.limits!.requestsPerMinute,
        if (config.limits!.maxTurnTokens != null)
          'max_turn_tokens': config.limits!.maxTurnTokens,
        if (config.limits!.maxSessionTokens != null)
          'max_session_tokens': config.limits!.maxSessionTokens,
        if (config.limits!.maxRequestTokens != null)
          'max_request_tokens': config.limits!.maxRequestTokens,
      },
    if (config.theme != null || config.themeVariant != null)
      'theme': {
        if (config.themeVariant != null) 'variant': config.themeVariant,
        if (config.theme != null) ...config.theme!.toMap(),
      },
    if (config.prompts.isNotEmpty)
      'prompts': {
        for (final e in config.prompts.entries) e.key: {'identity': e.value},
      },
    if (config.trustDefault != null) 'trust': {'default': config.trustDefault},
  };
  return TomlDocument.fromMap(map).toString();
}

/// Write [config] to `<tinaDir>/config` as TOML (best-effort chmod 600, since
/// the file may hold API keys). Creates the directory if needed. Returns the
/// path written. [tinaDir] is injectable for tests.
///
/// Throws [ConfigWriteException] (not a raw [FileSystemException]) when the
/// write fails — e.g. when the config is on a read-only mount (the sandbox
/// binds `~/.tina/config` as `:ro`). Callers surface this as an in-modal error
/// or a host warning instead of letting it crash the app.
String writeUserConfig(
  UserConfig config, {
  required Map<String, String> env,
  Directory? tinaDir,
}) {
  final file = userConfigFile(env, tinaDir: tinaDir);
  try {
    if (!file.parent.existsSync()) file.parent.createSync(recursive: true);
    file.writeAsStringSync(userConfigToToml(config));
  } on FileSystemException catch (e) {
    throw ConfigWriteException(file.path, e.osError?.message ?? e.message);
  }
  // Best-effort 0600 — no-op on non-Unix / if chmod is unavailable. A failed
  // chmod (e.g. read-only mount where the write above already threw) is not a
  // ConfigWriteException: the file content landed or didn't, and chmod failing
  // to tighten perms is a separate, non-fatal concern.
  try {
    Process.runSync('chmod', ['600', file.path]);
  } catch (_) {}
  return file.path;
}

/// Raised by [writeUserConfig] when the config file can't be written. Carries
/// the target path and the OS message so overlays can render a precise error
/// (e.g. "Read-only file system") instead of dumping a stack trace.
class ConfigWriteException implements Exception {
  final String path;
  final String message;
  ConfigWriteException(this.path, this.message);

  @override
  String toString() {
    final m = message.isEmpty ? 'write failed' : message;
    return 'Could not write $path: $m';
  }
}

const _kConfigTemplate = '''# tina user config (~/.tina/config).
# Edits here persist across launches, so you can drop the matching CLI flags
# and env vars. Precedence when both are set: CLI flag > this file > env var.

# Schema version — leave at 1. tina refuses a file whose version it doesn't
# understand, so an edit here only matters if you upgraded/downgraded tina.
version = 1

[default]
# Built-in providers: anthropic, openai, deepseek, gemini, glm, grok,
# longcat, mistral, nim, qwen, tencent. Set `model` to any model the
# provider offers (use `/model <name>` in the REPL to list them).
provider = "anthropic"
model    = "claude-sonnet-4-6"

# Optional: route every normal chat turn through a DOT workflow instead of the
# main agent. Name a workflow in ~/.tina/workflows (the seeded file is
# "default", edited with `/workflow edit default`), or "none" to disable the
# presence-based default.dot routing and use the plain single-agent path.
# workflow = "default"

# Sub-agent model tiers — a spec's modelTier resolves through this map. These
# two are the built-in defaults (applied when the table is absent); edit to
# override per key, e.g. point `light` at a cheaper provider.
[tiers]
heavy = "anthropic/claude-sonnet-4-6"
light = "anthropic/claude-haiku-4-5"

# Per-provider credentials / base URL. api_key   -> <PROVIDER>_API_KEY,
# auth_token -> <PROVIDER>_AUTH_TOKEN (bearer), base_url -> <PROVIDER>_BASE_URL.
# These reach every agent (main + sub-agents), replacing the env vars.
[providers.anthropic]
api_key = "sk-ant-..."
# auth_token = "..."
# base_url  = "https://..."

# Custom / OpenAI- or Anthropic-compatible endpoints. Set `wire` to register a
# NEW provider id (referenced as "<id>/<model>") or to REPLACE a built-in's wire
# format. `wire = "anthropic"` speaks Anthropic /v1/messages; `"openai"` speaks
# OpenAI /chat/completions (the default for new ids). `base_url` is required when
# `wire` is set. Example: Z.AI's Anthropic-compatible endpoint, model glm-5.2.
#
# [providers.zai]
# base_url   = "https://api.z.ai/api/anthropic"
# auth_token = "<z.ai key>"     # -> Authorization: Bearer
# wire       = "anthropic"
# # then reference as:  zai/glm-5.2   (the on-wire model name is the bare "glm-5.2")
#
# Repoint the built-in `glm` at z.ai instead (bare `glm-5.2` still resolves):
# [providers.glm]
# base_url   = "https://api.z.ai/api/anthropic"
# auth_token = "<z.ai key>"
# wire       = "anthropic"

# Spend / rate-limit guardrails — one ledger covers every agent (main +
# orchestrator + all scouts). Any value of 0 means "no limit" for that field.
# [limits]
# max_global_tokens    = 50000000   # total tokens this app session; trips a hard abort
# max_session_tokens   = 10000000   # main agent per-session (trips the pause dialog)
# max_turn_tokens      = 1000000    # main agent per-turn
# max_request_tokens   = 200000     # main agent single-request input
# max_sub_agent_tokens = 2000000    # per sub-agent session (they otherwise run uncapped)
# requests_per_minute  = 0          # global RPM throttle (0 = disabled)

# Terminal color theme. Values are ANSI SGR parameter strings (e.g. "31" for red
# foreground, "97;40" for bright-white-on-black). Omit any key to use the
# shipped default. Truecolor is supported: "38;2;r;g;b" for foreground,
# "48;2;r;g;b" for background. Set `variant = "light"` or `variant = "dark"`
# to select a full theme preset (overridden by any explicit values below).
# [theme]
# variant = "light"
# [theme.chat]
# user_bar = "97;40"
# agent_text = "30"
# [theme.border]
# focus = "36"
# selection = "33"
# [theme.border.busy]
# rail = "38;2;30;110;130"
# head = "1;38;2;175;255;255"
''';
