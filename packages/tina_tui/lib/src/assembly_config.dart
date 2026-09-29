/// Global configuration for the application assembly. Provider settings keep
/// the legacy TOML shape; no legacy application code is imported here.
library;

import 'dart:io' show File, Platform;

import 'package:tina_llm/tina_llm.dart';
import 'package:tina_core/tina_core.dart' show validatePluginId;
import 'package:toml/toml.dart';
import 'provider_config.dart';
import 'package:tina_providers/tina_providers.dart';
export 'provider_config.dart';

/// The schema version this reader understands. The file declares its
/// version with a top-level `version = N`; a reader that finds another
/// version refuses the file rather than guessing.
const int kTinaConfigVersion = 1;

const defaultApprovalChannel = 'tina/approvals-tui';

const defaultPluginIds = <String>[
  'tina/classification',
  'tina/chat-tui',
  'tina/panels-tui',
  'tina/mode-tui',
  'tina/activity-tui',
  'tina/persistence',
  'tina/plans',
  'tina/goals',
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
  const TinaConfig(
      {this.limits = const RequestLimits(),
      this.theme = const {},
      this.reasoningEffort,
      this.thinkingBudget,
      this.maxOutputTokens = 8192,
      this.providerId,
      required this.model,
      this.plugins = defaultPluginIds,
      this.approvalChannel = defaultApprovalChannel,
      this.providers = const {},
      this.descriptors = builtinDescriptors});

  /// The provider id from the config — null when the file did not name
  /// one, which sends a bare model down the Anthropic wire.
  final String? providerId;

  /// The model label the provider will be built with.
  final String model;
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
  /// were used.
  String? get note => path == null
      ? null
      : 'config: $path — '
          '${config.providerId == null ? 'anthropic wire' : config.providerId}'
          '/${config.model}';
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
  String get note => 'config: $problem — falling back to '
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
  final file = File(path ?? defaultConfigPath(environment));
  if (!file.existsSync()) {
    return const TinaConfigOk(TinaConfig(model: kTinaDefaultModel));
  }
  final String text;
  try {
    text = file.readAsStringSync();
  } catch (e) {
    return TinaConfigProblem(
        'cannot read $file: $e', const TinaConfig(model: kTinaDefaultModel));
  }
  final Map<String, dynamic> parsed;
  try {
    parsed = TomlDocument.parse(text).toMap();
  } catch (_) {
    return TinaConfigProblem('$file is not valid config syntax',
        const TinaConfig(model: kTinaDefaultModel));
  }
  return parseTinaConfig(parsed,
      path: file.path,
      descriptors: descriptors ?? configuredDescriptors(environment));
}

/// Legacy discovery is a read-only startup input; explicit config still wins.
List<ProviderDescriptor> configuredDescriptors(
    [Map<String, String> environment = const {}]) {
  final env = environment.isEmpty ? Platform.environment : environment;
  if (env['COCOON_MODELS_DEV'] == '0') return builtinDescriptors;
  final home = env['HOME'] ?? Platform.environment['HOME'];
  return home == null
      ? builtinDescriptors
      : cachedProviderDescriptors(
          '$home/.tina/cache/models.dev.providers.json');
}

/// Parse an already-read document, also used to validate settings before save.
TinaConfigResult parseTinaConfig(
  Map<String, dynamic> parsed, {
  String path = 'config',
  List<ProviderDescriptor> descriptors = builtinDescriptors,
}) {
  final file = path;
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
      final settings =
          ProviderSettings.parse(id, Map<String, dynamic>.from(entry.value));
      providers[id] = settings;
      resolvedDescriptors[id] =
          settings.descriptor(id, resolvedDescriptors[id]);
    }
  }
  for (final entry in providers.entries) {
    for (final member in entry.value.members) {
      final parts = member.split('/');
      if (!resolvedDescriptors.containsKey(parts.first) ||
          (providers[parts.first]?.members.isNotEmpty ?? false) ||
          (parts.length > 1 && parts.skip(1).join('/').isEmpty)) {
        throw FormatException(
            'providers.${entry.key}.members must name existing, non-pool providers with nonempty model IDs');
      }
    }
  }
  var plugins = defaultPluginIds;
  var approvalChannel = defaultApprovalChannel;
  if (parsed.containsKey('plugins')) {
    final table = parsed['plugins'];
    if (table is! Map ||
        table.keys.any((key) =>
            key != 'enabled' &&
            key != 'approval_channel' &&
            key != 'overrides')) {
      throw FormatException(
          '[plugins] supports enabled, overrides and approval_channel');
    }
    if (table.containsKey('approval_channel')) {
      final channel = table['approval_channel'];
      if (channel is! String)
        throw FormatException('approval_channel must be a plugin ID');
      try {
        validatePluginId(channel);
      } on ArgumentError {
        throw FormatException(
            'approval_channel must be a publisher/name plugin ID');
      }
      approvalChannel = channel;
    }
    if (table.containsKey('enabled')) {
      final enabled = table['enabled'];
      if (enabled is! List || enabled.any((id) => id is! String)) {
        throw FormatException(
            '[plugins].enabled must be an array of plugin IDs');
      }
      plugins = List<String>.unmodifiable(enabled.cast<String>());
      final seen = <String>{};
      for (final id in plugins) {
        try {
          validatePluginId(id);
        } on ArgumentError {
          throw FormatException(
              'invalid plugin ID "$id": expected publisher/name');
        }
        if (!seen.add(id)) throw FormatException('duplicate plugin ID: $id');
      }
    }
  }
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
            approvalChannel: approvalChannel));
  }
  final section = parsed['default'];
  if (section is! Map<String, dynamic>) {
    return TinaConfigProblem(
        '$file has no [default] section',
        TinaConfig(
            model: kTinaDefaultModel,
            plugins: plugins,
            approvalChannel: approvalChannel));
  }
  final provider = section['provider'];
  if (provider != null && provider is! String) {
    return TinaConfigProblem(
        '$file: [default] provider must be a string',
        TinaConfig(
            model: kTinaDefaultModel,
            plugins: plugins,
            approvalChannel: approvalChannel));
  }
  final model = section['model'];
  if (model is! String || model.isEmpty) {
    return TinaConfigProblem(
        '$file has no [default] model',
        TinaConfig(
            providerId: provider as String?,
            model: kTinaDefaultModel,
            plugins: plugins,
            approvalChannel: approvalChannel));
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
            approvalChannel: approvalChannel));
  }
  if (providerId != null && !resolvedDescriptors.containsKey(providerId)) {
    return TinaConfigProblem(
        '$file: unknown provider "$providerId"',
        TinaConfig(
            model: modelId,
            plugins: plugins,
            approvalChannel: approvalChannel));
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
          !['none', 'minimal', 'low', 'medium', 'high', 'xhigh', 'max']
              .contains(effort)))
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
            'theme values must be ANSI color numbers separated by semicolons');
    }
  }

  validateTheme(theme);
  return TinaConfigOk(
      TinaConfig(
          limits: RequestLimits.fromMap(table('limits')),
          theme: Map.unmodifiable(theme),
          reasoningEffort: effort as String?,
          thinkingBudget: integer('thinking_budget'),
          maxOutputTokens: maxOutput,
          providerId: providerId,
          model: modelId,
          plugins: plugins,
          approvalChannel: approvalChannel,
          providers: Map.unmodifiable(providers),
          descriptors: List.unmodifiable(resolvedDescriptors.values)),
      path: path);
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
    String id, List<ProviderDescriptor> descriptors) {
  for (final d in descriptors) {
    if (d.id == id) return d;
  }
  return null;
}

String defaultConfigPath([Map<String, String> environment = const {}]) {
  final home = environment['HOME'] ??
      (() {
        try {
          return Platform.environment['HOME'];
        } catch (_) {
          return null;
        }
      })();
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
          'plugin overrides must map plugin IDs to true or false');
    }
    try {
      validatePluginId(entry.key as String);
    } on ArgumentError {
      throw FormatException('invalid plugin override ID: ${entry.key}');
    }
    result[entry.key as String] = entry.value as bool;
  }
  return result;
}

void validateWorkspacePlugins(Map<String, dynamic> values) {
  final plugins = values['plugins'];
  if (plugins == null) return;
  if (plugins is! Map ||
      plugins.keys
          .any((key) => key != 'overrides' && key != 'approval_channel')) {
    throw FormatException(
        'workspace [plugins] supports overrides and approval_channel; use overrides instead of an enabled list');
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
          'approval_channel must be a publisher/name plugin ID');
    }
  }
}
