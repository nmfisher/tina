import 'dart:convert';
import 'package:tina_settings/tina_settings.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_providers/tina_providers.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'assembly_config.dart';
import 'layout_strategies.dart';
import 'session_context.dart';

SettingCatalog createSettingsCatalog(
    PluginRegistry<SessionPluginContext> registry, TinaConfig config) {
  final catalog = SettingCatalog();
  for (final id in registry.ids) {
    final manifest = registry.definition(id);
    // Delivery is an exclusive role, not a set of independent enable switches.
    if (!manifest.provides.any((role) => role.name == approvalChannel.name)) {
      catalog.register(SettingDefinition<bool>(
          id: '$id/enabled',
          label: id,
          description: manifest.description,
          defaultValue: defaultPluginIds.contains(id),
          kind: SettingKind.toggle,
          applyAt: manifest.live ? ApplyAt.whenIdle : ApplyAt.restart,
          configPath: ['plugins', 'overrides', id]));
    }
    for (final setting in manifest.settings) {
      catalog.register(setting);
    }
  }
  // The registry's delivery channels, in registration order.
  final channels = [
    for (final id in registry.ids)
      if (registry
          .definition(id)
          .provides
          .any((role) => role.name == approvalChannel.name))
        registry.definition(id)
  ];
  catalog.register(SettingDefinition<String>(
      id: 'tina/approvals/channel',
      label: 'Approval delivery',
      description:
          'Selects the plugin that presents approval requests. Exactly one delivery channel is selected.',
      // A registry that does not carry the default channel (the wasm
      // registry omits the TUI plugins) falls back to its first
      // registered channel, so the setting stays constructible.
      defaultValue: registry.ids.any((id) => id == defaultApprovalChannel)
          ? defaultApprovalChannel
          : channels.first.id,
      kind: SettingKind.choice,
      choices: [for (final definition in channels) definition.id],
      scopes: {SettingScope.global, SettingScope.workspace},
      applyAt: ApplyAt.restart,
      scopeReason: 'Approval delivery is selected when a conversation opens.',
      configPath: ['plugins', 'approval_channel']));
  // The chat screen arrangement (docs/native-layout-strategies.md).
  // Selected when the session opens; `/layout` swaps it live without a
  // restart.
  catalog.register(SettingDefinition<String>(
      id: 'tina/layout/strategy',
      label: 'Layout strategy',
      description:
          'How the chat screen is arranged: default (65/35 split at 100 '
          'columns), focus (equal 50/50 halves from 80 columns) or '
          'two-column (info panel on the left from 80 columns).',
      defaultValue: 'default',
      kind: SettingKind.choice,
      choices: layoutStrategyFactories.keys.toList(growable: false),
      scopes: {SettingScope.global, SettingScope.workspace},
      applyAt: ApplyAt.restart,
      scopeReason:
          'The layout strategy is selected when a conversation opens; '
          'use /layout to swap it live.',
      configPath: ['layout_strategy']));
  refreshProviderDefinitions(catalog, config);
  return catalog;
}

void refreshProviderDefinitions(SettingCatalog catalog, TinaConfig config) {
  final ids = {...config.providers.keys, config.providerId ?? 'anthropic'};
  for (final id in ids) {
    if (config.providers[id]?.members.isNotEmpty ?? false) continue;
    final descriptor = config.descriptors.where((d) => d.id == id).firstOrNull;
    if (descriptor == null) continue;
    for (final definition in providerGenerationSettings(id,
        defaultOutput: descriptor.models[config.model]?.maxOutput ??
            config.maxOutputTokens)) {
      catalog.replace(definition);
    }
  }
}


/// The effective-document merge, extracted from the filesystem backend
/// so any settings backend (a preloaded snapshot under wasm) computes
/// identically: the global document with every catalog definition
/// rewritten to null, then overlaid by the first layer (session first)
/// that carries the definition's value.
Map<String, dynamic> mergeSettingLayers({
  required Map<String, dynamic> globalDocument,
  required Map<SettingScope, Map<String, Object?>> layers,
  required Iterable<SettingDefinition<Object>> definitions,
}) {
  Map<String, dynamic> copy(Map<String, dynamic> values) =>
      Map<String, dynamic>.from(jsonDecode(jsonEncode(values)) as Map);

  void put(Map<String, dynamic> values, List<String> path, Object? value) {
    var parent = values;
    for (final part in path.take(path.length - 1)) {
      if (value == null && !parent.containsKey(part)) return;
      parent = parent.putIfAbsent(part, () => <String, dynamic>{})
          as Map<String, dynamic>;
    }
    if (value == null) {
      parent.remove(path.last);
    } else {
      parent[path.last] = value;
    }
  }

  final result = copy(globalDocument);
  (result['plugins'] as Map?)?.remove('enabled');
  for (final definition in definitions) {
    put(result, definition.configPath, null);
    for (final scope in SettingScope.values) {
      if (layers[scope]!.containsKey(definition.id)) {
        final value = layers[scope]![definition.id];
        if (definition.writeConfig != null) {
          definition.writeConfig!(result, value);
        } else {
          put(result, definition.configPath, value);
        }
        break;
      }
    }
  }
  return result;
}
