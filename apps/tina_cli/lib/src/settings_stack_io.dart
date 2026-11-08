import 'package:tina_host/tina_host.dart' show PluginRegistry;
import 'package:tina_llm/tina_llm.dart' show ProviderDescriptor;
import 'package:tina_settings/tina_settings.dart';

import 'plugin_catalog.dart' show firstPartyPlugins;
import 'scoped_config.dart';
import 'session_context.dart';

/// The native settings machinery: the full first-party registry and the
/// filesystem-backed settings backend (see `settings_stack.dart`).
PluginRegistry<SessionPluginContext> nativePluginRegistry() =>
    firstPartyPlugins();

SettingsBackend nativeSettingsBackend({
  required SettingCatalog catalog,
  required String globalPath,
  required String workspacePath,
  required List<ProviderDescriptor> descriptors,
  required void Function(Map<String, dynamic>) validateSelection,
  void Function()? onChanged,
}) =>
    ConfigSettingsBackend(
      catalog: catalog,
      globalPath: globalPath,
      workspacePath: workspacePath,
      descriptors: descriptors,
      validateSelection: validateSelection,
      onChanged: onChanged,
    );

String? nativeProtectedPermissionsPath(SettingsBackend backend) =>
    backend is ConfigSettingsBackend
        ? backend.permissionStore.file?.parent.path
        : null;
