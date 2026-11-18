/// Global configuration for the application assembly. Provider settings keep
/// the legacy TOML shape; no legacy application code is imported here.
library;

import 'app_io.dart';
import 'package:tina_llm/tina_llm.dart';
import 'package:tina_core/tina_core.dart' show validatePluginId;
import 'package:toml/toml.dart';
import 'package:tina_mcp/tina_mcp.dart' show McpServerConfig;
import 'provider_config.dart';
import 'legacy_provider_cache.dart';
import 'package:tina_providers/tina_providers.dart';
export 'provider_config.dart';

/// The schema version this reader understands. The file declares its
/// version with a top-level `version = N`; a reader that finds another
/// version refuses the file rather than guessing.
const int kTinaConfigVersion = 1;

const defaultApprovalChannel = 'tina/approvals-tui';

/// Preserve selections written before the system-instruction plugin rename.
String canonicalPluginId(String id) =>
    id == 'tina/persona' ? 'tina/system-instruction' : id;

/// v1 configs listed optional features only; these were previously implicit.
const retiredPluginIds = {'tina/mode-tui'};
const legacyProfilePlugins = <String>[
  'tina/providers',
  'tina/system-instruction',
  'tina/mode',
  'tina/tools',
  'tina/approvals',
];

List<String> pluginBaseline(List<String> ids, {int selectionVersion = 1}) => [
  ...{
    if (selectionVersion == 1) ...legacyProfilePlugins,
    for (final id in ids)
      if (!retiredPluginIds.contains(id)) canonicalPluginId(id),
  },
];

const defaultPluginIds = <String>[
  ...legacyProfilePlugins,
  'tina/shell',
  'tina/classification',
  'tina/chat-tui',
  'tina/session-controls',
  'tina/rewind',
  'tina/status-strip-tui',
  'tina/cwd-tui',
  'tina/panels-tui',
  'tina/activity-tui',
  'tina/bg-tui',
  'tina/mcp',
  'tina/persistence',
  'tina/channel',
  'tina/channel-tui',
  'tina/plans',
  'tina/goals',
  'tina/tasks',
  'tina/auto-compact',
  'tina/subagents',
  'tina/update',
  'tina/update-tui',
];

/// Where tina's config lives today.
const String kTinaConfigPath = '.tina/config';

/// Default model label, also used by tests that inject a ScriptedProvider.
/// The production assembly still uses its real provider factory.
const String kTinaDefaultModel = 'scripted';

/// The parsed `~/.tina/config`, narrowed to what the assembly needs.
final class TinaConfig {
  const TinaConfig({
    this.limits = const RequestLimits(),
    this.theme = const {},
    this.reasoningEffort,
    this.thinkingBudget,
    this.maxOutputTokens = 8192,
    this.providerId,
    required this.model,
    this.profile = 'default',
    this.profiles = const {},
    this.profilesTable = false,
    this.plugins = defaultPluginIds,
    this.approvalChannel = defaultApprovalChannel,
    this.providers = const {},
    this.descriptors = builtinDescriptors,
  });

  /// The provider id from the config — null when the file did not name
  /// one, which sends a bare model down the Anthropic wire.
  final String? providerId;

  /// The model label the provider will be built with.
  final String model;

  /// The active profile's name.
  final String profile;

  /// Named model-leg bundles. A config without a `profiles` table carries
  /// the synthesized `default` profile (from `model` + `providerId`), so
  /// fresh checkouts and legacy configs behave identically.
  final Map<String, ModelProfile> profiles;

  /// True when the config file declared a `[profiles]` table itself — the
  /// presets are authored config, not the synthesized `default`. Surfaces
  /// like `--models` stay quiet for legacy configs.
  final bool profilesTable;

  /// The active profile. The synthesized `default` profile covers configs
  /// that declare none (including problem fallbacks).
  ModelProfile get activeProfile =>
      profiles[profile] ??
      ModelProfile(
          name: profile,
          main: ModelLeg(provider: providerId, model: model));

  /// The active profile's main leg as a `provider/model` reference,
  /// falling back to the `[default] provider`/`model` lines — the model
  /// the session starts with.
  String get mainModelReference =>
      activeProfile.legReference(ProfileLeg.main,
          sessionProvider: providerId ?? 'anthropic') ??
      (providerId == null ? 'anthropic/$model' : '$providerId/$model');

  final RequestLimits limits;
  final Map<String, dynamic> theme;
  final String? reasoningEffort;
  final int? thinkingBudget;
  final int maxOutputTokens;

  /// An explicit list replaces the default feature plugins.
  final List<String> plugins;
  final String approvalChannel;
  final Map<String, ProviderSettings> providers;
  final List<ProviderDescriptor> descriptors;
}

/// How reading the config went: [config] on success, [problem] when the
/// file exists but cannot be honored. A missing file is a *success* with
/// the default model — a fresh checkout must run, not nag.
sealed class TinaConfigResult {
  const TinaConfigResult();

  TinaConfig get config => switch (this) {
    TinaConfigOk(:final resolved) => resolved,
    TinaConfigProblem(:final resolved) => resolved,
  };

  /// One status line for the front end's banner, or null when nothing was
  /// read (a missing config file is silent).
  String? get note;
}

/// The file was read (or was absent) and a model was resolved.
final class TinaConfigOk extends TinaConfigResult {
  const TinaConfigOk(this.resolved, {this.path});

  final TinaConfig resolved;

  /// The file that was read; null when the config file was absent.
  final String? path;

  /// One status line for the front end's banner, e.g.
  /// `config: ~/.tina/config — glm/glm-5.3-flashx`. Null when defaults
  /// were used. Names the active profile's main model — for a legacy
  /// config that is exactly the `[default] provider`/`model` pair, and
  /// no profile is appended (nothing nags).
  String? get note => path == null
      ? null
      : 'config: $path — ${config.mainModelReference}'
        '${config.profile == 'default' ? '' : ' · profile ${config.profile}'}';
}

/// The file exists but cannot be honored: bad syntax, wrong version, or
/// no model anywhere. [config] retains a fallback for callers inspecting the
/// result; the application assembly rejects the problem before creating a
/// session, so invalid config cannot silently re-enable default plugins.
final class TinaConfigProblem extends TinaConfigResult {
  const TinaConfigProblem(this.problem, this.resolved);

  final String problem;

  final TinaConfig resolved;

  /// One status line for the front end's banner.
  String get note =>
      'config: $problem — falling back to '
      '${config.providerId == null ? 'the anthropic wire' : config.providerId}'
      '/${config.model}';
}

/// Read and parse the config file at [path] (default `~/.tina/config`),
/// resolving the model reference against [descriptors]. Offline: absent an
/// injected descriptor set, reads the legacy provider cache as well.
TinaConfigResult loadTinaConfig({
  String? path,
  List<ProviderDescriptor>? descriptors,
  Map<String, String> environment = const {},
}) {
  final io = defaultAppIo();
  final configPath = path ?? defaultConfigPath(environment);
  final String? read;
  try {
    read = io.readTextIfExists(configPath);
  } catch (e) {
    return TinaConfigProblem(
      'cannot read $configPath: $e',
      const TinaConfig(model: kTinaDefaultModel),
    );
  }
  if (read == null) {
    return const TinaConfigOk(TinaConfig(model: kTinaDefaultModel));
  }
  final String text = read;
  final Map<String, dynamic> parsed;
  try {
    parsed = TomlDocument.parse(text).toMap();
  } catch (_) {
    return TinaConfigProblem(
      '$configPath is not valid config syntax',
      const TinaConfig(model: kTinaDefaultModel),
    );
  }
  return parseTinaConfig(
    parsed,
    path: configPath,
    descriptors: descriptors ?? configuredDescriptors(environment),
  );
}

/// Legacy discovery is a read-only startup input; explicit config still wins.
List<ProviderDescriptor> configuredDescriptors([
  Map<String, String> environment = const {},
]) {
  String? ambient(String name) =>
      environment.isNotEmpty ? environment[name] : defaultAppIo().env(name);
  if (ambient('COCOON_MODELS_DEV') == '0') return builtinDescriptors;
  final home = ambient('HOME');
  return home == null
      ? builtinDescriptors
      : cachedProviderDescriptors(
          '$home/.tina/cache/models.dev.providers.json',
        );
}

/// Parse an already-read document, also used to validate settings before save.
TinaConfigResult parseTinaConfig(
  Map<String, dynamic> parsed, {
  String path = 'config',
  List<ProviderDescriptor> descriptors = builtinDescriptors,
}) {
  final file = path;
  McpServerConfig.parse(parsed['mcp']);
  final providers = <String, ProviderSettings>{};
  final resolvedDescriptors = {for (final d in descriptors) d.id: d};
  final providerTables = parsed['providers'];
  if (providerTables != null) {
    if (providerTables is! Map)
      throw FormatException('[providers] must be a table');
    for (final entry in providerTables.entries) {
      final id = entry.key as String;
      if (!RegExp(r'^[a-zA-Z][a-zA-Z0-9_-]*$').hasMatch(id) ||
          entry.value is! Map) {
        throw FormatException('invalid provider table');
      }
      final settings = ProviderSettings.parse(
        id,
        Map<String, dynamic>.from(entry.value),
      );
      providers[id] = settings;
      resolvedDescriptors[id] = settings.descriptor(
        id,
        resolvedDescriptors[id],
      );
    }
  }
  for (final entry in providers.entries) {
    for (final member in entry.value.members) {
      final parts = member.split('/');
      if (!resolvedDescriptors.containsKey(parts.first) ||
          (providers[parts.first]?.members.isNotEmpty ?? false) ||
          (parts.length > 1 && parts.skip(1).join('/').isEmpty)) {
        throw FormatException(
          'providers.${entry.key}.members must name existing, non-pool providers with nonempty model IDs',
        );
      }
    }
  }
  var plugins = defaultPluginIds;
  var approvalChannel = defaultApprovalChannel;
  if (parsed.containsKey('plugins')) {
    final table = parsed['plugins'];
    if (table is! Map ||
        table.keys.any(
          (key) =>
              key != 'enabled' &&
              key != 'approval_channel' &&
              key != 'overrides' &&
              key != 'selection_version',
        )) {
      throw FormatException(
        '[plugins] supports enabled, overrides and approval_channel',
      );
    }
    if (table.containsKey('approval_channel')) {
      final channel = table['approval_channel'];
      if (channel is! String)
        throw FormatException('approval_channel must be a plugin ID');
      try {
        validatePluginId(channel);
      } on ArgumentError {
        throw FormatException(
          'approval_channel must be a publisher/name plugin ID',
        );
      }
      approvalChannel = channel;
    }
    if (table.containsKey('enabled')) {
      final enabled = table['enabled'];
      if (enabled is! List || enabled.any((id) => id is! String)) {
        throw FormatException(
          '[plugins].enabled must be an array of plugin IDs',
        );
      }
      plugins = List<String>.unmodifiable(enabled.cast<String>());
      final seen = <String>{};
      for (final id in plugins) {
        try {
          validatePluginId(id);
        } on ArgumentError {
          throw FormatException(
            'invalid plugin ID "$id": expected publisher/name',
          );
        }
        if (!seen.add(id)) throw FormatException('duplicate plugin ID: $id');
      }
    }
  }
  final selectionVersion =
      (parsed['plugins'] as Map?)?['selection_version'] ?? 1;
  if (selectionVersion != 1 && selectionVersion != 2)
    throw const FormatException('Unsupported plugin selection version');
  plugins = pluginBaseline(plugins, selectionVersion: selectionVersion as int);
  final overrides = parsePluginOverrides(parsed['plugins']);
  final selected = plugins.toSet();
  for (final entry in overrides.entries) {
    if (entry.value) {
      selected.add(entry.key);
    } else {
      selected.remove(entry.key);
    }
  }
  plugins = List.unmodifiable(selected);
  final version = parsed['version'];
  if (version != null && version != kTinaConfigVersion) {
    return TinaConfigProblem(
      '$file is config version $version; this reader understands '
      'version $kTinaConfigVersion',
      TinaConfig(
        model: kTinaDefaultModel,
        plugins: plugins,
        approvalChannel: approvalChannel,
      ),
    );
  }
  final section = parsed['default'];
  if (section is! Map<String, dynamic>) {
    return TinaConfigProblem(
      '$file has no [default] section',
      TinaConfig(
        model: kTinaDefaultModel,
        plugins: plugins,
        approvalChannel: approvalChannel,
      ),
    );
  }
  final provider = section['provider'];
  if (provider != null && provider is! String) {
    return TinaConfigProblem(
      '$file: [default] provider must be a string',
      TinaConfig(
        model: kTinaDefaultModel,
        plugins: plugins,
        approvalChannel: approvalChannel,
      ),
    );
  }
  final model = section['model'];
  if (model is! String || model.isEmpty) {
    return TinaConfigProblem(
      '$file has no [default] model',
      TinaConfig(
        providerId: provider as String?,
        model: kTinaDefaultModel,
        plugins: plugins,
        approvalChannel: approvalChannel,
      ),
    );
  }
  // `provider/model` in the model wins over the section's provider — the
  // old engine's rule, so a config written for tina reads the same here.
  var providerId = provider as String?;
  var modelId = model;
  final slash = model.indexOf('/');
  if (slash > 0 &&
      (providerId == null ||
          resolvedDescriptors.containsKey(model.substring(0, slash)))) {
    providerId = model.substring(0, slash);
    modelId = model.substring(slash + 1);
  }
  if (modelId.trim().isEmpty) {
    return TinaConfigProblem(
      '$file has an empty model ID',
      TinaConfig(
        model: kTinaDefaultModel,
        plugins: plugins,
        approvalChannel: approvalChannel,
      ),
    );
  }
  if (providerId != null && !resolvedDescriptors.containsKey(providerId)) {
    return TinaConfigProblem(
      '$file: unknown provider "$providerId"',
      TinaConfig(
        model: modelId,
        plugins: plugins,
        approvalChannel: approvalChannel,
      ),
    );
  }
  final profiles = parseProfilesConfig(parsed,
      descriptors: resolvedDescriptors.keys.toSet());
  final profileName = parsed['profile'];
  if (profileName != null && profileName is! String) {
    throw const FormatException('profile must be a profile name');
  }
  final activeProfile = profileName as String? ?? 'default';
  // `default` is always resolvable (synthesized from [default] below);
  // any other name must exist in the profiles table.
  if (activeProfile != 'default' && !profiles.containsKey(activeProfile)) {
    throw FormatException(
        'profile "$activeProfile" is not defined in [profiles]');
  }
  Map<String, dynamic> table(String key) {
    final value = parsed[key];
    if (value == null) return {};
    if (value is! Map) throw FormatException('[$key] must be a table');
    return Map<String, dynamic>.from(value);
  }

  int? integer(String key) {
    final value = section[key];
    if (value != null && (value is! int || value < 0))
      throw FormatException('default.$key must be a nonnegative integer');
    return value as int?;
  }

  final maxOutput = integer('max_tokens') ?? 8192;
  if (maxOutput == 0)
    throw FormatException('default.max_tokens must be positive');
  final effort = section['reasoning_effort'];
  if (effort != null &&
      (effort is! String ||
          ![
            'none',
            'minimal',
            'low',
            'medium',
            'high',
            'xhigh',
            'max',
          ].contains(effort)))
    throw FormatException('invalid default.reasoning_effort');
  final theme = table('theme');
  if (theme['variant'] != null &&
      !['light', 'dark', 'default'].contains(theme['variant']))
    throw FormatException('theme.variant must be light, dark or default');
  void validateTheme(Map values) {
    for (final entry in values.entries) {
      if (entry.value is Map) {
        validateTheme(entry.value as Map);
      } else if (entry.value is! String ||
          (entry.key != 'variant' &&
              !RegExp(r'^[0-9;]*$').hasMatch(entry.value as String)))
        throw FormatException(
          'theme values must be ANSI color numbers separated by semicolons',
        );
    }
  }

  validateTheme(theme);
  // A config without a profiles table synthesizes `default` from the
  // `[default] provider`/`model` lines — migration without migration:
  // legacy configs and fresh checkouts behave identically, nothing nags.
  final resolvedProfiles = profiles.containsKey(activeProfile)
      ? profiles
      : {
          ...profiles,
          'default': ModelProfile(
              name: 'default',
              main: ModelLeg(provider: providerId, model: modelId)),
        };
  return TinaConfigOk(
    TinaConfig(
      limits: RequestLimits.fromMap(table('limits')),
      theme: Map.unmodifiable(theme),
      reasoningEffort: effort as String?,
      thinkingBudget: integer('thinking_budget'),
      maxOutputTokens: maxOutput,
      providerId: providerId,
      model: modelId,
      profile: activeProfile,
      profiles: Map.unmodifiable(resolvedProfiles),
      profilesTable: profiles.isNotEmpty,
      plugins: plugins,
      approvalChannel: approvalChannel,
      providers: Map.unmodifiable(providers),
      descriptors: List.unmodifiable(resolvedDescriptors.values),
    ),
    path: path,
  );
}

/// Parse the `profiles` table: each profile a named bundle of model legs.
/// A profile value is either a one-line `"provider/model"` string (the
/// main leg) or a table with `main`, `subagent` and `approver` legs
/// (`judge` is the deprecated spelling of `approver`). A leg is a
/// `"provider/model"` string or a `{ provider, model }` table; omitting
/// the provider inherits the session's provider. Validation is per leg
/// and names the profile and leg.
Map<String, ModelProfile> parseProfilesConfig(Map<String, dynamic> parsed,
    {required Set<String> descriptors}) {
  final raw = parsed['profiles'];
  if (raw == null) return {};
  if (raw is! Map) throw const FormatException('[profiles] must be a table');
  final profiles = <String, ModelProfile>{};
  for (final entry in raw.entries) {
    final name = entry.key as String;
    final legs = <ProfileLeg, ModelLeg>{};
    if (entry.value is String || entry.value is Map) {
      if (entry.value is String) {
        legs[ProfileLeg.main] =
            _parseProfileLeg('profiles.$name.main', entry.value, descriptors);
      } else {
        final table = Map<String, dynamic>.from(entry.value as Map);
        for (final leg in table.entries) {
          final ProfileLeg which;
          switch (leg.key) {
            case 'main':
              which = ProfileLeg.main;
            case 'subagent':
              which = ProfileLeg.subagent;
            case 'approver':
              which = ProfileLeg.approver;
            case 'judge':
              // `judge` is the deprecated spelling from the design draft;
              // an explicit `approver` key wins over it.
              if (table.containsKey('approver')) continue;
              which = ProfileLeg.approver;
            case _:
              throw FormatException(
                  'profiles.$name.${leg.key} is not a model leg '
                  '(main, subagent, approver)');
          }
          legs[which] = _parseProfileLeg(
              'profiles.$name.${leg.key}', leg.value, descriptors);
        }
      }
    } else {
      throw FormatException(
          'profiles.$name must be a "provider/model" string or a table of '
          'model legs');
    }
    profiles[name] = ModelProfile(
      name: name,
      main: legs[ProfileLeg.main],
      subagent: legs[ProfileLeg.subagent],
      approver: legs[ProfileLeg.approver],
    );
  }
  return profiles;
}

ModelLeg _parseProfileLeg(
    String where, Object? value, Set<String> descriptors) {
  ModelLeg leg(String? provider, String model) {
    if (model.trim().isEmpty) {
      throw FormatException('$where has an empty model ID');
    }
    if (provider != null && !descriptors.contains(provider)) {
      throw FormatException('$where names unknown provider "$provider"');
    }
    return ModelLeg(provider: provider, model: model);
  }

  if (value is String) {
    final slash = value.indexOf('/');
    if (slash > 0) {
      return leg(value.substring(0, slash), value.substring(slash + 1));
    }
    return leg(null, value);
  }
  if (value is Map) {
    if (value.keys.any((key) => key != 'provider' && key != 'model')) {
      throw FormatException('$where must be a table with provider and model');
    }
    final provider = value['provider'];
    final model = value['model'];
    if (provider != null && provider is! String) {
      throw FormatException('$where: provider must be a string');
    }
    if (model is! String) {
      throw FormatException('$where: model is required');
    }
    return leg(provider as String?, model);
  }
  throw FormatException(
      '$where must be a "provider/model" string or a table with provider and model');
}

/// The model reference the way the old engine prints it: `provider/model`
/// when a provider is named, the bare model when the anthropic wire is
/// implied. This is the label [HostConfig.model] carries and the factory
/// receives.
String configModelReference(TinaConfig config) => config.providerId == null
    ? config.model
    : '${config.providerId}/${config.model}';

/// Look one descriptor up by id among [descriptors].
ProviderDescriptor? descriptorByIdFor(
  String id,
  List<ProviderDescriptor> descriptors,
) {
  for (final d in descriptors) {
    if (d.id == id) return d;
  }
  return null;
}

String defaultConfigPath([Map<String, String> environment = const {}]) {
  final home = environment['HOME'] ?? defaultAppIo().env('HOME');
  if (home == null || home.isEmpty) return kTinaConfigPath;
  return '$home/$kTinaConfigPath';
}

/// Per-plugin overrides work at global and workspace scope. Missing means inherit.
Map<String, bool> parsePluginOverrides(Object? pluginTable) {
  if (pluginTable == null) return {};
  if (pluginTable is! Map) throw FormatException('[plugins] must be a table');
  final raw = pluginTable['overrides'];
  if (raw == null) return {};
  if (raw is! Map) throw FormatException('[plugins.overrides] must be a table');
  final result = <String, bool>{};
  for (final entry in raw.entries) {
    if (entry.key is! String || entry.value is! bool) {
      throw FormatException(
        'plugin overrides must map plugin IDs to true or false',
      );
    }
    try {
      validatePluginId(entry.key as String);
    } on ArgumentError {
      throw FormatException('invalid plugin override ID: ${entry.key}');
    }
    final id = entry.key as String;
    final canonical = canonicalPluginId(id);
    // An explicit current name takes precedence over its legacy alias.
    if (id == canonical || !raw.containsKey(canonical)) {
      result[canonical] = entry.value as bool;
    }
  }
  return result;
}

void validateWorkspacePlugins(Map<String, dynamic> values) {
  final plugins = values['plugins'];
  if (plugins == null) return;
  if (plugins is! Map ||
      plugins.keys.any(
        (key) => key != 'overrides' && key != 'approval_channel',
      )) {
    throw FormatException(
      'workspace [plugins] supports overrides and approval_channel; use overrides instead of an enabled list',
    );
  }
  parsePluginOverrides(plugins);
  final channel = plugins['approval_channel'];
  if (channel != null) {
    if (channel is! String)
      throw FormatException('approval_channel must be a plugin ID');
    try {
      validatePluginId(channel);
    } on ArgumentError {
      throw FormatException(
        'approval_channel must be a publisher/name plugin ID',
      );
    }
  }
}
