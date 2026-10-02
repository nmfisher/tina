import 'dart:io';
import 'package:toml/toml.dart';
import 'package:tina_settings/tina_settings.dart';

final stepLimitSetting = SettingDefinition<int>(
    id: 'tina/step-limit/max_steps_per_turn',
    label: 'Model rounds per turn',
    description:
        'Foreground model rounds per turn; tool calls within a response count as one round. 0 means unlimited.',
    defaultValue: 0,
    kind: SettingKind.integer,
    minimum: 0,
    applyAt: ApplyAt.nextRequest);

/// Global-only numeric policy. Plugin enablement is separately scoped by host.
final class StepLimitConfig {
  StepLimitConfig(this.path);
  final String path;

  static int validate(Object? value) {
    if (value is! int || value < 0) {
      throw const FormatException(
          'Step limit must be a non-negative integer (0 means unlimited).');
    }
    return value;
  }

  Map<String, dynamic> _read() {
    final file = File(path);
    return file.existsSync()
        ? TomlDocument.parse(file.readAsStringSync()).toMap()
        : <String, dynamic>{};
  }

  int read() {
    final values = _read();
    final plugins = values['plugin_config'];
    if (plugins != null && plugins is! Map) {
      throw const FormatException('plugin_config must be a table');
    }
    final settings = (plugins as Map?)?['tina/step-limit'];
    if (settings != null && settings is! Map) {
      throw const FormatException('tina/step-limit config must be a table');
    }
    return validate((settings as Map?)?['max_steps_per_turn'] ?? 0);
  }

  void save(int value) {
    validate(value);
    // Re-read at save time to preserve other plugins and provider settings.
    final values = _read();
    final plugins =
        Map<String, dynamic>.from(values['plugin_config'] as Map? ?? {});
    final settings =
        Map<String, dynamic>.from(plugins['tina/step-limit'] as Map? ?? {});
    settings['max_steps_per_turn'] = value;
    plugins['tina/step-limit'] = settings;
    values['plugin_config'] = plugins;
    final target = File(path);
    target.parent.createSync(recursive: true);
    final directory = target.parent.createTempSync('.step-limit-');
    try {
      final pending = File('${directory.path}/config');
      pending.writeAsStringSync(TomlDocument.fromMap(values).toString(),
          flush: true);
      if (!Platform.isWindows) {
        final result = Process.runSync('chmod', ['600', pending.path]);
        if (result.exitCode != 0)
          throw FileSystemException('Cannot secure config', pending.path);
      }
      pending.renameSync(target.path);
    } finally {
      directory.deleteSync(recursive: true);
    }
  }
}
