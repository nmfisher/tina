import 'package:tina_host/tina_host.dart' show PluginRegistry;
import 'package:tina_llm/tina_llm.dart' show ProviderDescriptor;
import 'package:tina_settings/tina_settings.dart';
import 'assembly_config.dart';
import 'session_context.dart';
import 'settings_catalog.dart';
import 'scoped_config.dart' show ConfigSettingsBackend;
import 'settings_stack_unsupported.dart'
    if (dart.library.io) 'settings_stack_io.dart';

/// The scoped-settings stack every entry point shares: registry → catalog →
/// file backend → session-scoped facade. Assembly wires the rest of the TUI
/// around it; `tina config` and first-run run it without a session.
final class ScopedSettingsStack {
  ScopedSettingsStack._(
      {required this.registry,
      required this.catalog,
      required this.backend,
      required this.settings,
      required this.effectiveDocument});

  /// The assembly's default registry (the platform's first-party set).
  static PluginRegistry<SessionPluginContext> defaultPluginRegistry() =>
      nativePluginRegistry();

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
    PluginRegistry<SessionPluginContext>? registry,
    required List<ProviderDescriptor> descriptors,
    TinaConfig? config,
    void Function()? onConfigurationChanged,
    SettingsBackend? backend,
    Map<String, dynamic> Function()? effectiveDocument,
  }) {
    final resolvedRegistry = registry ?? nativePluginRegistry();
    final resolved = config ?? TinaConfig(model: kTinaDefaultModel);
    final catalog = createSettingsCatalog(resolvedRegistry, resolved);
    final resolvedBackend = backend ??
        nativeSettingsBackend(
          catalog: catalog,
          globalPath: globalPath,
          workspacePath: workspacePath,
          descriptors: descriptors,
          validateSelection: (values) {
            final parsed = parseTinaConfig(values, descriptors: descriptors);
            if (parsePluginOverrides(values['plugins'])[parsed.config
                    .approvalChannel] ==
                false) {
              throw ArgumentError(
                  '${parsed.config.approvalChannel} is the selected approval channel');
            }
            resolvedRegistry.validate(
                {...parsed.config.plugins, parsed.config.approvalChannel});
          },
          onChanged: onConfigurationChanged,
        );
    final settings = ScopedSettings(catalog: catalog, backend: resolvedBackend);
    return ScopedSettingsStack._(
        registry: resolvedRegistry,
        catalog: catalog,
        backend: resolvedBackend,
        settings: settings,
        effectiveDocument: resolvedBackend is ConfigSettingsBackend
            ? (resolvedBackend as ConfigSettingsBackend).effectiveDocument
            : (effectiveDocument ??
                (throw StateError(
                    'an injected settings backend must supply its merge'))));
  }

  /// The plugin registry the catalog was built from.
  final PluginRegistry<SessionPluginContext> registry;



  /// Setting definitions shared by every panel in this process.
  final SettingCatalog catalog;

  /// The settings backend: the native filesystem adapter, or whatever a
  /// composition root injected (a preloaded snapshot under wasm).
  final SettingsBackend backend;

  /// The merged effective document, however the backend computes it:
  /// the native backend's own merge, or the injected function a
  /// composition root supplied with its backend.
  final Map<String, dynamic> Function() effectiveDocument;

  /// The path the native backend protects (its permissions store's
  /// directory), when there is one.
  String? get protectedPermissionsPath =>
      nativeProtectedPermissionsPath(backend);

  /// Session-scoped facade assembly and plugins read and write through.
  final ScopedSettings settings;
}
