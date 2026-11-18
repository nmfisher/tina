import 'package:tina_settings/tina_settings.dart';

// The classifier settings (instruction, model, timeout) moved to the
// profiles module in tina_providers, next to the approver leg that now
// picks the judgment model. Their ids keep the `tina/mode/` prefix and
// storage paths, so saved values read unchanged; tina_mode registers
// them from there (see classifierSettings in package:tina_providers).

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
