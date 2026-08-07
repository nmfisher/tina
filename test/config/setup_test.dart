import 'package:tina/config/setup.dart';
import 'package:tina/config/user_config.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/overlay_fixtures.dart';

/// Drives [runSetupWizard] with a canned prompt. The wizard's stdout narration
/// is harmless; assertions are on the written config and the return value.
void main() {
  final tmp = TempTinaDir();
  late List<String> answers;
  String? prompt(String _) => answers.isEmpty ? null : answers.removeAt(0);

  setUp(() => tmp.setUp('tina_setup_'));
  tearDown(tmp.tearDown);

  test('writes the default provider/model + key', () {
    final registry = ProviderRegistry(env: {})
      ..register(fakeProviderDescriptor('alpha', models: ['a1', 'a2']))
      ..register(fakeProviderDescriptor('beta', models: ['b1']));
    answers = ['1', '1', 'key-alpha', '']; // provider, model, key, confirm

    final wrote = runSetupWizard(
      env: {},
      registry: registry,
      tinaDir: tmp.dir,
      prompt: prompt,
    );

    expect(wrote, isTrue);
    final c = loadUserConfig(env: {}, tinaDir: tmp.dir);
    expect(c.defaultProvider, 'alpha');
    expect(c.defaultModel, 'a1');
    expect(c.providers['alpha']?.apiKey, 'key-alpha');
  });

  test('auth-optional provider: no key prompt', () {
    final registry = ProviderRegistry(env: {})
      ..register(
          fakeProviderDescriptor('local', models: ['m1'], optional: true));
    answers = ['1', '1', '']; // provider, model, confirm — no key asked

    final wrote = runSetupWizard(
      env: {},
      registry: registry,
      tinaDir: tmp.dir,
      prompt: prompt,
    );

    expect(wrote, isTrue);
    final c = loadUserConfig(env: {}, tinaDir: tmp.dir);
    expect(c.defaultProvider, 'local');
    expect(c.defaultModel, 'm1');
    expect(c.providers, isEmpty); // no key collected
  });

  test('skipping the provider writes nothing and returns false', () {
    final registry = ProviderRegistry(env: {})
      ..register(fakeProviderDescriptor('alpha', models: ['a1']));
    answers = ['']; // skip the default provider

    final wrote = runSetupWizard(
      env: {},
      registry: registry,
      tinaDir: tmp.dir,
      prompt: prompt,
    );

    expect(wrote, isFalse);
    expect(userConfigFile({}, tinaDir: tmp.dir).existsSync(), isFalse);
  });

  group('buildSetupConfig', () {
    test('limits are included when passed', () {
      const limits = LimitsConfig(
        maxGlobalTokens: 1,
        maxSubAgentTokens: 2,
        requestsPerMinute: 3,
        maxTurnTokens: 4,
        maxSessionTokens: 5,
        maxRequestTokens: 6,
      );
      final cfg =
          buildSetupConfig(keys: {}, limits: limits, defaultProvider: 'a');
      expect(cfg.limits, limits);
    });

    test('limits default to null (omitted) — the first-run wizard path', () {
      final cfg = buildSetupConfig(keys: {});
      expect(cfg.limits, isNull,
          reason: 'the stdin wizard passes no limits → no [limits] section');
    });

    test('themeVariant is threaded through to UserConfig', () {
      final cfg = buildSetupConfig(
        keys: {},
        defaultProvider: 'a',
        defaultModel: 'b',
        themeVariant: 'dark',
      );
      expect(cfg.themeVariant, 'dark');
    });

    test('themeVariant defaults to null (omitted)', () {
      final cfg = buildSetupConfig(keys: {});
      expect(cfg.themeVariant, isNull);
    });
  });
}
