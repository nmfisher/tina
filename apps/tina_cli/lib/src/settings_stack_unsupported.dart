import 'package:tina_host/tina_host.dart' show PluginRegistry;
import 'package:tina_settings/tina_settings.dart';

import 'native_kinds.dart' show ConfigSettingsBackend;
import 'session_context.dart';

/// The no-`dart:io` settings machinery: a wasm composition root injects
/// its own backend and registry before the assembly boots.
PluginRegistry<SessionPluginContext> nativePluginRegistry() =>
    throw UnsupportedError(
        'no native plugin registry on this platform: inject one');

ConfigSettingsBackend nativeSettingsBackend({
  required SettingCatalog catalog,
  required String globalPath,
  required String workspacePath,
  required List<Object> descriptors,
  required void Function(Map<String, dynamic>) validateSelection,
  void Function()? onChanged,
}) =>
    throw UnsupportedError(
        'no native settings backend on this platform: inject one');

String? nativeProtectedPermissionsPath(SettingsBackend backend) => null;
