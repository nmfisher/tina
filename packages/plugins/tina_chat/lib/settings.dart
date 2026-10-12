import 'package:tina_settings/tina_settings.dart';

final terminalAlertsSetting = SettingDefinition<bool>(
  id: 'tina/chat-tui/terminal_alerts',
  label: 'Terminal alerts',
  description:
      'Request terminal tab attention when a response finishes or an '
      'approval needs an answer. The terminal controls the icon, sound and '
      'clearing the alert when you return to the tab.',
  defaultValue: true,
  kind: SettingKind.toggle,
  scopes: const {SettingScope.global},
  scopeReason: 'All conversation panels share the terminal tab.',
  configPath: const ['terminal', 'alerts'],
);

final themeSetting = SettingDefinition<String>(
  id: 'tina/chat-tui/theme',
  label: 'Theme',
  description: 'Terminal colors shared by every panel in this app.',
  defaultValue: 'default',
  kind: SettingKind.choice,
  choices: const ['default', 'light', 'dark'],
  scopes: const {SettingScope.global},
  scopeReason:
      'One terminal shares one theme across its panels; this preference is global.',
  configPath: const ['theme', 'variant'],
);
