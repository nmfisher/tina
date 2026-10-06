import 'package:tina_host/tina_host.dart' show PluginRegistry;
import 'package:tina_llm/tina_llm.dart' show ProviderDescriptor;
import 'package:tina_settings/tina_settings.dart';

import 'assembly_config.dart';
import 'plugin_catalog.dart';
import 'scoped_config.dart';
import 'settings_catalog.dart';

/// The scoped-settings stack every entry point shares: registry → catalog →
/// file backend → session-scoped facade. Assembly wires the rest of the TUI
/// around it; `tina config` and first-run run it without a session.
final class ScopedSettingsStack {
  ScopedSettingsStack._(
      {required this.registry,
      required this.catalog,
      required this.backend,
      required this.settings});

  /// Builds the stack over the given config paths. [globalPath] is the
  /// explicit or default global config file; [workspacePath] is the
  /// workspace-local overlay. Passing the same file for both collapses the
  /// workspace layer into global (the backend's same-file canonicalization).
  ///
  /// [configurationUpdates] receives backend change notifications; assembly
  /// passes its shared hub so panels refresh together. [registry] defaults
  /// to the first-party plugin registry; [config] seeds provider generation
  /// definitions in the catalog.
  static ScopedSettingsStack build({
    required String globalPath,
    required String workspacePath,
    PluginRegistry<TuiPluginContext>? registry,
    required List<ProviderDescriptor> descriptors,
    TinaConfig? config,
    void Function()? onConfigurationChanged,
  }) {
    final resolvedRegistry = registry ?? firstPartyPlugins();
    final resolved = config ?? TinaConfig(model: kTinaDefaultModel);
    final catalog = createSettingsCatalog(resolvedRegistry, resolved);
    final backend = ConfigSettingsBackend(
        catalog: catalog,
        globalPath: globalPath,
        workspacePath: workspacePath,
        descriptors: descriptors,
        validateSelection: (values) {
          final parsed = parseTinaConfig(values, descriptors: descriptors);
          if (parsePluginOverrides(values['plugins'])[parsed.config.approvalChannel] ==
              false) {
            throw ArgumentError(
                '${parsed.config.approvalChannel} is the selected approval channel');
          }
          resolvedRegistry.validate(
              {...parsed.config.plugins, parsed.config.approvalChannel});
        },
        onChanged: onConfigurationChanged);
    final settings = ScopedSettings(catalog: catalog, backend: backend);
    return ScopedSettingsStack._(
        registry: resolvedRegistry,
        catalog: catalog,
        backend: backend,
        settings: settings);
  }

  /// The plugin registry the catalog was built from.
  final PluginRegistry<TuiPluginContext> registry;

  /// Setting definitions shared by every panel in this process.
  final SettingCatalog catalog;

  /// Filesystem adapter over the global and workspace config files.
  final ConfigSettingsBackend backend;

  /// Session-scoped facade assembly and plugins read and write through.
  final ScopedSettings settings;
}
