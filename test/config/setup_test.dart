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

  test(
      'two tiers, two providers: writes both tiers + each key, default = heavy',
      () {
    final registry = ProviderRegistry(env: {})
      ..register(fakeProviderDescriptor('alpha', models: ['a1', 'a2']))
      ..register(fakeProviderDescriptor('beta', models: ['b1']));
    answers = ['1', '1', 'key-alpha', '2', '1', 'key-beta', ''];

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
    expect(c.tiers, {'heavy': 'alpha/a1', 'light': 'beta/b1'});
    expect(c.providers['alpha']?.apiKey, 'key-alpha');
    expect(c.providers['beta']?.apiKey, 'key-beta');
  });

  test('same provider for both tiers: key collected once', () {
    final registry = ProviderRegistry(env: {})
      ..register(fakeProviderDescriptor('alpha', models: ['a1', 'a2']));
    answers = ['1', '1', 'key-alpha', '1', '2', ''];

    final wrote = runSetupWizard(
      env: {},
      registry: registry,
      tinaDir: tmp.dir,
      prompt: prompt,
    );

    expect(wrote, isTrue);
    final c = loadUserConfig(env: {}, tinaDir: tmp.dir);
    expect(c.tiers, {'heavy': 'alpha/a1', 'light': 'alpha/a2'});
    expect(c.providers.keys, ['alpha']);
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
    expect(c.tiers, {'heavy': 'local/m1'});
    expect(c.providers, isEmpty); // no key collected
  });

  test('skipping every tier writes nothing and returns false', () {
    final registry = ProviderRegistry(env: {})
      ..register(fakeProviderDescriptor('alpha', models: ['a1']));
    answers = ['', '']; // skip heavy provider, skip light provider

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
      final cfg = buildSetupConfig(tiers: {}, keys: {}, limits: limits);
      expect(cfg.limits, limits);
    });

    test('limits default to null (omitted) — the first-run wizard path', () {
      final cfg = buildSetupConfig(tiers: {}, keys: {});
      expect(cfg.limits, isNull,
          reason: 'the stdin wizard passes no limits → no [limits] section');
    });

    test('themeVariant is threaded through to UserConfig', () {
      final cfg = buildSetupConfig(
        tiers: {'heavy': 'a/b'},
        keys: {},
        themeVariant: 'dark',
      );
      expect(cfg.themeVariant, 'dark');
    });

    test('themeVariant defaults to null (omitted)', () {
      final cfg = buildSetupConfig(tiers: {}, keys: {});
      expect(cfg.themeVariant, isNull);
    });
  });
}
