import 'package:tina_providers/tina_providers.dart' show classifierInstructionSetting;
import 'package:tina_settings/tina_settings.dart';

/// The native settings backend sources this override from private approvals.
String? readProjectPermissionInstructions(ScopedSettings? settings) {
  if (settings == null || !settings.catalog.contains(classifierInstructionSetting.id)) {
    return null;
  }
  final instruction = settings.override(
      classifierInstructionSetting, SettingScope.workspace) as String?;
  final trimmed = instruction?.trim();
  return trimmed == null || trimmed.isEmpty ? null : trimmed;
}
