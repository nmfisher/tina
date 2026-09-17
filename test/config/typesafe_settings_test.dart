import 'package:test/test.dart';
import 'package:tina/config/user_config.dart';
import 'package:tina/tui/settings_panel.dart';

import '../helpers/overlay_fixtures.dart';

void main() {
  final tmp = TempTinaDir();
  setUp(() => tmp.setUp('tina_typesafe_config_'));
  tearDown(tmp.tearDown);

  test('dedicated settings round-trip and survive unrelated patches', () {
    final config = UserConfig.fromMap({
      'typesafe': {'api_key': 'judgment-key', 'model': 'jev-pinned'},
      'default': {'provider': 'alpha', 'model': 'chat', 'workflow': 'review'},
      'providers': {
        'alpha': {'api_key': 'chat-key'},
      },
    });
    expect(config.isEmpty, isFalse);
    expect(config.typeSafe?.apiKey, 'judgment-key');
    expect(config.providers.keys, ['alpha']);
    writeUserConfig(config, env: const {}, tinaDir: tmp.dir);
    writeUserConfigPatch(env: const {}, tinaDir: tmp.dir, themeVariant: 'dark');
    final loaded = loadUserConfig(env: const {}, tinaDir: tmp.dir);
    expect(loaded.typeSafe, config.typeSafe);
    expect(loaded.defaultWorkflow, 'review');
    expect(loaded.copyWith(defaultModel: 'next').typeSafe, config.typeSafe);
    expect(userConfigToToml(loaded), contains('[typesafe]'));
  });

  test(
    'clear removes saved credential and preserves model and other sections',
    () {
      writeUserConfig(
        const UserConfig(
          typeSafe: TypeSafeSettings(apiKey: 'old', model: 'jev-pinned'),
          defaultProvider: 'alpha',
        ),
        env: const {},
        tinaDir: tmp.dir,
      );
      writeUserConfigPatch(env: const {}, tinaDir: tmp.dir, typeSafeApiKey: '');
      final loaded = loadUserConfig(env: const {}, tinaDir: tmp.dir);
      expect(loaded.typeSafe?.apiKey, isNull);
      expect(loaded.typeSafe?.model, 'jev-pinned');
      expect(loaded.defaultProvider, 'alpha');
      expect(userConfigToToml(loaded), isNot(contains('old')));
    },
  );

  test(
    'key patch reloads current model instead of overwriting newer edits',
    () {
      writeUserConfig(
        const UserConfig(typeSafe: TypeSafeSettings(model: 'new-model')),
        env: const {},
        tinaDir: tmp.dir,
      );
      writeUserConfigPatch(
        env: const {},
        tinaDir: tmp.dir,
        typeSafeApiKey: 'key',
      );
      expect(
        loadUserConfig(env: const {}, tinaDir: tmp.dir).typeSafe,
        const TypeSafeSettings(apiKey: 'key', model: 'new-model'),
      );
      expect(
        writeUserConfigPatch(
          env: const {},
          tinaDir: tmp.dir,
          typeSafeApiKey: 'key',
        ),
        isNull,
      );
    },
  );

  test('empty section omitted and clearing an absent key does not write', () {
    expect(
      writeUserConfigPatch(env: const {}, tinaDir: tmp.dir, typeSafeApiKey: ''),
      isNull,
    );
    expect(userConfigFile(const {}, tinaDir: tmp.dir).existsSync(), isFalse);
    expect(const UserConfig(typeSafe: TypeSafeSettings()).isEmpty, isTrue);
    expect(
      userConfigToToml(const UserConfig(typeSafe: TypeSafeSettings())),
      isNot(contains('[typesafe]')),
    );
    expect(
      const UserConfig(typeSafe: TypeSafeSettings(apiKey: 'key')).isEmpty,
      isFalse,
    );
  });
}
