import 'dart:io';
import 'package:test/test.dart';
import 'package:toml/toml.dart';
import 'package:tina_step_limit/src/config.dart';

void main() {
  late Directory directory;
  late File file;
  late StepLimitConfig config;
  setUp(() {
    directory = Directory.systemTemp.createTempSync('step-limit-test-');
    file = File('${directory.path}/config');
    config = StepLimitConfig(file.path);
  });
  tearDown(() => directory.deleteSync(recursive: true));

  test('absent configuration means unlimited', () {
    expect(config.read(), 0);
    file.writeAsStringSync('[default]\nmodel = "test"\n');
    expect(config.read(), 0);
  });

  test('save preserves unrelated settings and reloads the numeric policy', () {
    file.writeAsStringSync('[providers.test]\napi_key = "\${TOKEN}"\n'
        '[plugin_config."other/plugin"]\nvalue = 42\n');
    config.save(27);
    expect(config.read(), 27);
    final values = TomlDocument.parse(file.readAsStringSync()).toMap();
    expect((values['providers'] as Map)['test']['api_key'], r'${TOKEN}');
    expect((values['plugin_config'] as Map)['other/plugin']['value'], 42);
    config.save(0);
    expect(config.read(), 0);
  });

  test('rejects negative and noninteger limits', () {
    for (final value in ['-1', '1.5', '"16"', 'true']) {
      file.writeAsStringSync(
          '[plugin_config."tina/step-limit"]\nmax_steps_per_turn = $value\n');
      expect(config.read, throwsFormatException);
    }
    expect(() => config.save(-1), throwsFormatException);
  });
}
