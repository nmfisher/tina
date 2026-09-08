import 'package:test/test.dart';
import 'package:tina/config.dart';
import 'package:tina/config/user_config.dart';
import 'package:tina/config/theme_mapper.dart';

void main() {
  test(
    'launch retains startup selection and explicit model source separately',
    () {
      final launch = Config.parse([
        '--model',
        'anthropic/explicit',
        '--resume',
        'saved',
        '--backend',
        'ansi',
        '--prompt',
        'task',
        '--no-trust',
      ], env: const {}).launch;
      expect(launch.runtime.runtimeType, RuntimeConfig);
      expect(launch.runtime.model, 'explicit');
      expect(launch.runtime.modelExplicit, isTrue);
      expect(launch.startup.resume.resumeSessionId, 'saved');
      expect(launch.startup.prompt, 'task');
      expect(launch.startup.nonInteractive, isTrue);
      expect(launch.startup.trustOverride, isFalse);
      expect(launch.terminal.backend, BackendChoice.ansi);
    },
  );

  test('file, environment and CLI precedence survive runtime projection', () {
    for (final entry in [
      (const <String>[], 'file-model', false, 71),
      (
        const ['--model', 'cli-model', '--max-turn-tokens', '82'],
        'cli-model',
        true,
        82,
      ),
    ]) {
      final (argv, model, explicit, budget) = entry;
      final config = Config.parse(
        argv,
        env: const {
          'ANTHROPIC_MODEL': 'env-model',
          'ANTHROPIC_BASE_URL': 'https://env.test',
        },
        userConfig: const UserConfig(
          defaultModel: 'file-model',
          limits: LimitsConfig(maxTurnTokens: 71),
        ),
      );
      expect(config.runtime.model, model);
      expect(config.runtime.modelExplicit, explicit);
      expect(config.runtime.maxTurnTokens, budget);
      expect(config.runtime.baseUrl, 'https://env.test');
    }
  });

  test('informational exits still bypass model and budget validation', () {
    for (final flag in ['--help', '--version', '--list', '--init-config']) {
      final launch = Config.parse([
        flag,
        '--model',
        'missing/model',
        '--max-steps',
        '-1',
      ], env: const {}).launch;
      expect(launch.runtime.apiKey, isEmpty);
      expect(
        launch.startup.showHelp ||
            launch.startup.showVersion ||
            launch.startup.listSessions ||
            launch.startup.initConfig,
        isTrue,
      );
    }
  });

  test('theme values are deeply immutable and map at the frontend', () {
    final color = [10, 20, 30];
    final raw = <String, dynamic>{
      'chat': {'user_bar': '93;41'},
      'border': {
        'busy': {'head_rgb': color},
      },
    };
    final overrides = ThemeOverrides(raw);
    color[0] = 99;
    (raw['chat'] as Map)['user_bar'] = 'changed';
    final theme = themeFromOverrides(overrides);
    expect(theme.chat.userBar, '93;41');
    expect(theme.border.busy.headRgb, [10, 20, 30]);
    expect(
      () => (overrides.values['chat'] as Map).clear(),
      throwsUnsupportedError,
    );
    final copy = overrides.toMap();
    (copy['chat'] as Map).clear();
    expect(themeFromOverrides(overrides).chat.userBar, '93;41');
  });

  test(
    'changing a named variant does not retain a stale persisted variant',
    () {
      final loaded = UserConfig.fromMap({
        'theme': {'variant': 'light'},
      });
      final changed = loaded.copyWith(themeVariant: 'dark');
      expect(changed.theme!.toMap(), isNot(contains('variant')));
      expect(userConfigToToml(changed), contains('dark'));
    },
  );
}
