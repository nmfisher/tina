import 'package:path/path.dart' as p;
import 'package:tina_host/tina_host.dart' show PluginRegistry;
import 'package:tina_llm/tina_llm.dart' show ProviderDescriptor;
import 'package:tina_settings/tina_settings.dart';

import 'plugin_catalog.dart' show firstPartyPlugins;
import 'native_kinds.dart' show ConfigSettingsBackend;
import 'scoped_config.dart' as scoped;
import 'session_context.dart';

/// The native settings machinery: the full first-party registry and the
/// filesystem-backed settings backend (see `settings_stack.dart`).
PluginRegistry<SessionPluginContext> nativePluginRegistry() =>
    firstPartyPlugins();

ConfigSettingsBackend nativeSettingsBackend({
  required SettingCatalog catalog,
  required String globalPath,
  required String workspacePath,
  required List<ProviderDescriptor> descriptors,
  required void Function(Map<String, dynamic>) validateSelection,
  void Function()? onChanged,
}) =>
    scoped.ConfigSettingsBackend(
      catalog: catalog,
      globalPath: globalPath,
      workspacePath: workspacePath,
      descriptors: descriptors,
      validateSelection: validateSelection,
      onChanged: onChanged,
    );

String? nativeProtectedPermissionsPath(SettingsBackend backend) {
  if (backend is! ConfigSettingsBackend) return null;
  final file = backend.permissionStore.filePath;
  return file == null ? null : p.dirname(file);
}
