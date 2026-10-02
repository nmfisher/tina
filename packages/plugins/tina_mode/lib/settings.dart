import 'package:tina_settings/tina_settings.dart';

final classifierInstructionSetting = SettingDefinition<String>(
  id: 'tina/mode/classifier_instruction',
  label: 'Auto-approval classifier instruction',
  description:
      'Your permission preferences, prepended to every auto-approval classification request. Session overrides are saved with this conversation. Approvals and the OS sandbox still enforce execution permissions.',
  defaultValue: '',
  kind: SettingKind.text,
  applyAt: ApplyAt.nextRequest,
);
