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

final classifierModelSetting = SettingDefinition<String>(
  id: 'tina/mode/classifier_model',
  label: 'Auto-approval classifier model',
  description:
      'Model for auto-approval judgments, for example "anthropic/claude-haiku". '
      'Empty follows this conversation\'s model. The provider must support '
      'structured output; unsupported models fall back with an error in the '
      'approval diagnostics.',
  defaultValue: '',
  kind: SettingKind.text,
  applyAt: ApplyAt.nextRequest,
);

final precedentSetting = SettingDefinition<String>(
  id: 'tina/mode/precedents',
  label: 'Approval precedents',
  description:
      'Remembers how similar permission requests were decided. "off" keeps no '
      'history. "evidence" shows past decisions to the auto-approval judge. '
      '"full" also runs an exact read-only request quietly after it has been '
      'approved twice. Precedents never grant network or unconfined access.',
  defaultValue: 'evidence',
  kind: SettingKind.choice,
  choices: const ['off', 'evidence', 'full'],
  applyAt: ApplyAt.immediately,
  scopeReason:
      'Learned decisions follow the workspace; the session scope lets one '
      'conversation try the feature without changing the default.',
);
