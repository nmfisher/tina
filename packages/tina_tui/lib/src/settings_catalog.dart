import 'package:tina_settings/tina_settings.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_providers/tina_providers.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'assembly_config.dart';
import 'plugin_catalog.dart';

SettingCatalog createSettingsCatalog(
    PluginRegistry<TuiPluginContext> registry, TinaConfig config) {
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
  catalog.register(SettingDefinition<String>(
      id: 'tina/approvals/channel',
      label: 'Approval delivery',
      description:
          'Selects the plugin that presents approval requests. Exactly one delivery channel is selected.',
      defaultValue: defaultApprovalChannel,
      kind: SettingKind.choice,
      choices: [
        for (final id in registry.ids)
          if (registry
              .definition(id)
              .provides
              .any((role) => role.name == approvalChannel.name))
            id
      ],
      scopes: {SettingScope.global, SettingScope.workspace},
      applyAt: ApplyAt.restart,
      scopeReason: 'Approval delivery is selected when a conversation opens.',
      configPath: ['plugins', 'approval_channel']));
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
