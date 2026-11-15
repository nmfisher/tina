import 'package:tina_settings/tina_settings.dart';

final commandWorkingDirectorySetting = SettingDefinition<String>(
  id: 'tina/tools/command_working_directory',
  label: 'Command working directory',
  description: 'Default directory for exec and bash calls. Blank uses the '
      'workspace; relative paths start there. A call can override this with '
      'working_directory. Changes apply to the next command.',
  defaultValue: '',
  kind: SettingKind.text,
  applyAt: ApplyAt.nextRequest,
  validate: (value) {
    if (value.contains('\u0000'))
      throw const FormatException('Invalid directory');
  },
);

final commandPathSetting = SettingDefinition<String>(
  id: 'tina/tools/command_path',
  label: 'Command PATH',
  description: 'Executable search directories separated by colons. Blank uses '
      'the built-in toolchain PATH, including /opt/homebrew/bin. Applies to '
      'both exec and bash without an export prelude. Changing PATH requires '
      'fresh command-prefix approvals.',
  defaultValue: '',
  kind: SettingKind.text,
  applyAt: ApplyAt.nextRequest,
  validate: (value) {
    if (value.contains('\u0000') ||
        value.isNotEmpty &&
            value.split(':').any((part) => !part.startsWith('/'))) {
      throw const FormatException('PATH entries must be absolute directories');
    }
  },
);

final commandEnvironmentSetting = SettingDefinition<Map<String, String>>(
  id: 'tina/tools/command_environment',
  label: 'Command environment variables',
  description: 'Explicit environment variables shared by this conversation’s '
      'commands, as a JSON object of string values. No variables are learned '
      'from shell exports. HOME, temporary directories, PATH and shell loader '
      'variables are managed separately. Changes require fresh prefix approvals.',
  defaultValue: const {},
  kind: SettingKind.object,
  secret: true,
  scopes: {SettingScope.session, SettingScope.global},
  scopeReason: 'Environment variables may contain credentials; repository '
      'settings cannot supply them.',
  applyAt: ApplyAt.nextRequest,
  decode: (value) {
    if (value is! Map ||
        value.keys.any((k) => k is! String) ||
        value.values.any((v) => v is! String)) {
      throw const FormatException('Use an object of string values');
    }
    return Map<String, String>.unmodifiable(value.cast<String, String>());
  },
  validate: (values) {
    for (final entry in values.entries) {
      if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(entry.key) ||
          entry.value.contains('\u0000') ||
          {
            'HOME',
            'TMPDIR',
            'TMP',
            'TEMP',
            'PATH',
            'ENV',
            'BASH_ENV',
            'SHELLOPTS',
            'BASHOPTS'
          }.contains(entry.key) ||
          entry.key.startsWith('LD_') ||
          entry.key.startsWith('DYLD_')) {
        throw FormatException(
            'Invalid or managed environment variable: ${entry.key}');
      }
    }
  },
);

final executionSettings = [
  commandWorkingDirectorySetting,
  commandPathSetting,
  commandEnvironmentSetting
];
