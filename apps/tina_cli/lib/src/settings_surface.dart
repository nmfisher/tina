/// The settings backend surface: what [ScopedSettings] consumers (and
/// the CI-named tests) touch on the app layer's `ConfigSettingsBackend`,
/// expressed on top of the portable [SettingsBackend] so one name serves
/// every view of it —
///
/// - natively, `scoped_config.dart`'s `ConfigSettingsBackend` implements
///   this surface over the real config files and the permission store;
/// - under wasm (and in analyzer configurations where the
///   `dart.library.io` conditional resolves the other way), the app
///   layer's `ConfigSettingsBackend` alias IS this surface, so members
///   like `workspacePath`, `permissionStore`, `setPluginInAllScopes`,
///   `effectiveDocument` and `draft` resolve identically either way.
library;

import 'package:tina_settings/tina_settings.dart';

import 'config_document.dart' show ConfigDocument;
import 'package:tina_tools/portable_tools.dart' show ToolCommandApprovals;

/// The config-backed settings backend as the app layer sees it.
abstract interface class ConfigSettingsSurface implements SettingsBackend {
  /// The global config file's path.
  String get globalPath;

  /// The workspace config file's path.
  String get workspacePath;

  /// The store of remembered command approvals.
  ToolCommandApprovals get permissionStore;

  /// Enables or disables a plugin in every scope at once.
  void setPluginInAllScopes(
    ScopedSettings settings,
    SettingDefinition<Object> definition,
    bool? enabled, {
    bool refresh = true,
  });

  /// The values one [scope]'s document holds, parsed.
  Map<String, dynamic> document(SettingScope scope);

  /// The merged effective document (all layers), optionally from
  /// explicit [layers].
  Map<String, dynamic> effectiveDocument({
    Map<SettingScope, Map<String, Object?>>? layers,
  });

  /// The document [scope] would become under [commit]'s edit.
  ConfigDocument draft(
    ScopedSettings settings,
    SettingScope scope, {
    void Function(Map<String, Object?>, Set<String>)? commit,
  });
}
