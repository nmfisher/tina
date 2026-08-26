import 'dart:io';

import 'package:tina/config/user_config.dart';
import 'package:tina_console/tina_console.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('UserConfig.fromMap', () {
    test('parses default and providers tables', () {
      final c = UserConfig.fromMap({
        'default': {
          'provider': 'anthropic',
          'model': 'claude-sonnet-4-6',
          'workflow': 'default',
        },
        'providers': {
          'anthropic': {
            'api_key': 'sk-ant-x',
            'base_url': 'https://example.test',
          },
        },
      });
      expect(c.defaultProvider, 'anthropic');
      expect(c.defaultModel, 'claude-sonnet-4-6');
      expect(c.defaultWorkflow, 'default');
      expect(c.providers['anthropic']?.apiKey, 'sk-ant-x');
      expect(c.providers['anthropic']?.baseUrl, 'https://example.test');
    });

    test('empty map → empty config', () {
      final c = UserConfig.fromMap({});
      expect(c.isEmpty, isTrue);
    });

    test('ignores unknown top-level keys', () {
      final c = UserConfig.fromMap({
        'unknown': 42,
        'default': {'provider': 'a'},
      });
      expect(c.defaultProvider, 'a');
      expect(c.isEmpty, isFalse);
    });

    test('parses a [theme] table', () {
      final c = UserConfig.fromMap({
        'theme': {
          'chat': {'user_bar': '92;100'},
          'border': {
            'focus': '35',
            'busy': {
              'rail': '38;2;11;22;33',
              'head': '1;38;2;44;55;66',
            },
          },
        },
      });
      expect(c.theme, isNotNull);
      expect(c.theme!.chat.userBar, '92;100');
      expect(c.theme!.border.focus, '35');
      expect(c.theme!.border.busy.rail, '38;2;11;22;33');
      expect(c.theme!.border.busy.headRgb, [44, 55, 66]);
      expect(c.isEmpty, isFalse);
    });

    test('parses a [limits] table', () {
      final c = UserConfig.fromMap({
        'limits': {
          'max_global_tokens': 5000,
          'max_sub_agent_tokens': 1000,
          'requests_per_minute': 30,
          'max_turn_tokens': 7,
          'max_session_tokens': 8,
          'max_request_tokens': 9,
        },
      });
      expect(c.limits?.maxGlobalTokens, 5000);
      expect(c.limits?.maxSubAgentTokens, 1000);
      expect(c.limits?.requestsPerMinute, 30);
      expect(c.limits?.maxTurnTokens, 7);
      expect(c.limits?.maxSessionTokens, 8);
      expect(c.limits?.maxRequestTokens, 9);
      expect(c.isEmpty, isFalse);
    });

    test('parses a [regions] table', () {
      final c = UserConfig.fromMap({
        'regions': {'model': 'deepseek/deepseek-chat'},
      });
      expect(c.regions?.model, 'deepseek/deepseek-chat');
      expect(c.isEmpty, isFalse);
    });

    test('parses a [prompts.<role>] table into role→identity', () {
      final c = UserConfig.fromMap({
        'prompts': {
          'main': {'identity': 'You are a bespoke main agent.'},
          'research': {'identity': 'line one\nline two'},
        },
      });
      expect(c.prompts, {
        'main': 'You are a bespoke main agent.',
        'research': 'line one\nline two',
      });
      expect(c.isEmpty, isFalse);
    });

    test('skips a prompt role whose identity is absent or empty', () {
      final c = UserConfig.fromMap({
        'prompts': {
          'main': {'identity': 'kept'},
          'research': {'identity': ''},
          'tester': {'not_identity': 'dropped'},
        },
      });
      expect(c.prompts, {'main': 'kept'});
    });

    test('parses provider members (a pool block); empty or non-list → null', () {
      final c = UserConfig.fromMap({
        'providers': {
          'mypool': {'members': ['nim', 'openrouter']},
          'empty': {'members': []},
          'bogus': {'members': 'nim'},
          'plain': {'base_url': 'https://example.test'},
        },
      });
      expect(c.providers['mypool']?.members, ['nim', 'openrouter']);
      expect(c.providers['empty']?.members, isNull,
          reason: 'an empty list is not a pool declaration');
      expect(c.providers['bogus']?.members, isNull);
      expect(c.providers['plain']?.members, isNull);
    });

    test('parses provider models ("id" or "id|name"); empty → null', () {
      final c = UserConfig.fromMap({
        'providers': {
          'zai': {
            'base_url': 'https://api.z.ai/api/anthropic',
            'wire': 'anthropic',
            'models': ['glm-5.2', 'glm-5.2-air|GLM 5.2 Air'],
          },
          'empty': {'models': []},
          'blank': {'models': ['', '  ']},
          'bogus': {'models': 'glm-5.2'},
          'plain': {'base_url': 'https://example.test'},
        },
      });
      expect(c.providers['zai']?.models, [
        const ProviderModelSpec(id: 'glm-5.2'),
        const ProviderModelSpec(id: 'glm-5.2-air', name: 'GLM 5.2 Air'),
      ], reason: '"id" and "id|display name" entries both parse');
      expect(c.providers['empty']?.models, isNull,
          reason: 'an empty list is not a models declaration');
      expect(c.providers['blank']?.models, isNull,
          reason: 'blank entries are dropped; nothing left to declare');
      expect(c.providers['bogus']?.models, isNull);
      expect(c.providers['plain']?.models, isNull);
    });
  });

  group('buildEnvOverlay', () {
    test('maps each provider field to <PREFIX>_*', () {
      final overlay = buildEnvOverlay(UserConfig(providers: {
        'anthropic': ProviderConfig(
            apiKey: 'sk-ant', authToken: 'tok', baseUrl: 'https://x.test'),
        'glm': ProviderConfig(apiKey: 'glm-key'),
      }));
      expect(overlay, {
        'ANTHROPIC_API_KEY': 'sk-ant',
        'ANTHROPIC_AUTH_TOKEN': 'tok',
        'ANTHROPIC_BASE_URL': 'https://x.test',
        'GLM_API_KEY': 'glm-key',
      });
    });

    test('empty config → empty overlay', () {
      expect(buildEnvOverlay(UserConfig.empty), isEmpty);
    });

    test('omits null fields', () {
      final overlay = buildEnvOverlay(UserConfig(providers: {
        'openai': ProviderConfig(authToken: 'only-token'),
      }));
      expect(overlay, {'OPENAI_AUTH_TOKEN': 'only-token'});
    });
  });

  group('loadUserConfig', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_config_');
    });
    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    File writeConfig(String contents) {
      final file = File(p.join(tmp.path, 'config'));
      file.writeAsStringSync(contents);
      return file;
    }

    test('missing file → empty', () {
      final c = loadUserConfig(env: {}, tinaDir: tmp);
      expect(c.isEmpty, isTrue);
    });

    test('parses a real TOML file end-to-end', () {
      writeConfig('''
[default]
provider = "anthropic"
model = "claude-sonnet-4-6"

[providers.anthropic]
api_key = "sk-ant-x"
base_url = "https://example.test"
''');
      final c = loadUserConfig(env: {}, tinaDir: tmp);
      expect(c.defaultProvider, 'anthropic');
      expect(c.defaultModel, 'claude-sonnet-4-6');
      expect(c.providers['anthropic']?.apiKey, 'sk-ant-x');
      expect(buildEnvOverlay(c), containsPair('ANTHROPIC_API_KEY', 'sk-ant-x'));
    });

    test('malformed TOML → empty (and does not throw)', () {
      writeConfig('this is = = not [valid toml');
      final c = loadUserConfig(env: {}, tinaDir: tmp);
      expect(c.isEmpty, isTrue);
    });

    test('explicit version = 1 loads', () {
      writeConfig('''
version = 1
[default]
provider = "anthropic"
''');
      final c = loadUserConfig(env: {}, tinaDir: tmp);
      expect(c.version, 1);
      expect(c.defaultProvider, 'anthropic');
    });

    test('unsupported version → empty (refused, not mis-parsed)', () {
      writeConfig('''
version = 99
[default]
provider = "anthropic"
''');
      final c = loadUserConfig(env: {}, tinaDir: tmp);
      expect(c.isEmpty, isTrue);
    });

    test('unknown top-level key warns but still loads the valid sections', () {
      // [setttings] is a typo for [default]; it must not silently disable the
      // rest of the file.
      writeConfig('''
version = 1
[setttings]
provider = "typo"

[default]
model = "claude-sonnet-4-6"

[providers.anthropic]
api_key = "sk-x"
''');
      final c = loadUserConfig(env: {}, tinaDir: tmp);
      expect(c.isEmpty, isFalse, reason: 'valid sections still load');
      expect(c.defaultModel, 'claude-sonnet-4-6');
      expect(c.providers['anthropic']?.apiKey, 'sk-x');
    });

    test('unknown provider key warns but the provider still loads', () {
      writeConfig('''
version = 1
[providers.anthropic]
api_key = "sk-x"
key = "typo"
''');
      final c = loadUserConfig(env: {}, tinaDir: tmp);
      expect(c.providers['anthropic']?.apiKey, 'sk-x');
    });

    test('models is a known provider key (no unknown-key warning, still loads)',
        () {
      // A hand-edited config listing models for a custom provider must load
      // without the "unknown key" recovery path dropping or ignoring it.
      writeConfig('''
version = 1
[providers.stub]
base_url = "http://localhost:8080/v1"
wire = "openai"
models = ["stub-1", "stub-2|Stub Two"]
''');
      final c = loadUserConfig(env: {}, tinaDir: tmp);
      expect(c.providers['stub']?.models, const [
        ProviderModelSpec(id: 'stub-1'),
        ProviderModelSpec(id: 'stub-2', name: 'Stub Two'),
      ]);
    });

    test('userConfigToToml round-trips through loadUserConfig', () {
      final original = UserConfig(
        defaultProvider: 'anthropic',
        defaultModel: 'claude-sonnet-4-6',
        defaultWorkflow: 'default',
        providers: {'anthropic': ProviderConfig(apiKey: 'sk-ant-x')},
      );
      writeUserConfig(original, env: {}, tinaDir: tmp);
      final loaded = loadUserConfig(env: {}, tinaDir: tmp);
      expect(loaded.defaultProvider, 'anthropic');
      expect(loaded.defaultModel, 'claude-sonnet-4-6');
      expect(loaded.defaultWorkflow, 'default');
      expect(loaded.providers['anthropic']?.apiKey, 'sk-ant-x');
    });

    test('provider models round-trip through the TOML file', () {
      writeUserConfig(
        UserConfig(providers: {
          'zai': ProviderConfig(
            baseUrl: 'https://api.z.ai/api/anthropic',
            wire: 'anthropic',
            models: const [
              ProviderModelSpec(id: 'glm-5.2'),
              ProviderModelSpec(id: 'glm-5.2-air', name: 'GLM 5.2 Air'),
            ],
          ),
        }),
        env: {},
        tinaDir: tmp,
      );
      // The raw file carries both forms ("id" bare, "id|name" with a display
      // name) — this is what a user hand-edits.
      final raw = File(p.join(tmp.path, 'config')).readAsStringSync();
      expect(raw, contains('glm-5.2-air|GLM 5.2 Air'));
      expect(raw, contains('glm-5.2'));
      final loaded = loadUserConfig(env: {}, tinaDir: tmp);
      expect(loaded.providers['zai']?.models, const [
        ProviderModelSpec(id: 'glm-5.2'),
        ProviderModelSpec(id: 'glm-5.2-air', name: 'GLM 5.2 Air'),
      ]);
    });

    test('[environment] auto_populate round-trips through loadUserConfig',
        () {
      writeUserConfig(
        UserConfig(trustDefault: 'ask', environmentAutoPopulate: 'always'),
        env: {},
        tinaDir: tmp,
      );
      final loaded = loadUserConfig(env: {}, tinaDir: tmp);
      expect(loaded.environmentAutoPopulate, 'always');
      // Absent → null (the caller resolves null → ask).
      writeUserConfig(UserConfig(trustDefault: 'ask'), env: {}, tinaDir: tmp);
      expect(loadUserConfig(env: {}, tinaDir: tmp).environmentAutoPopulate,
          isNull);
    });

    test('[environment] model round-trips and coexists with auto_populate',
        () {
      // Both keys live in ONE table: writing the model must not drop a
      // previously-persisted auto_populate (or vice versa).
      writeUserConfig(
        UserConfig(environmentAutoPopulate: 'always'),
        env: {},
        tinaDir: tmp,
      );
      writeUserConfig(
        loadUserConfig(env: {}, tinaDir: tmp)
            .copyWith(environmentModel: 'nim/google/diffusiongemma-26b-a4b-it'),
        env: {},
        tinaDir: tmp,
      );
      final loaded = loadUserConfig(env: {}, tinaDir: tmp);
      expect(loaded.environmentModel, 'nim/google/diffusiongemma-26b-a4b-it');
      expect(loaded.environmentAutoPopulate, 'always',
          reason: 'the model write must not clobber the sibling key');
      // Absent → null (the caller resolves null → the shipped default).
      writeUserConfig(const UserConfig(), env: {}, tinaDir: tmp);
      expect(loadUserConfig(env: {}, tinaDir: tmp).environmentModel, isNull);
    });

    test('[limits] min_request_interval_ms round-trips beside the other limits',
        () {
      writeUserConfig(
        const UserConfig(
            limits: LimitsConfig(requestsPerMinute: 30, maxTurnTokens: 1000)),
        env: {},
        tinaDir: tmp,
      );
      writeUserConfig(
        loadUserConfig(env: {}, tinaDir: tmp).copyWith(
            limits: const LimitsConfig(
                requestsPerMinute: 30,
                maxTurnTokens: 1000,
                minRequestIntervalMs: 250)),
        env: {},
        tinaDir: tmp,
      );
      final loaded = loadUserConfig(env: {}, tinaDir: tmp);
      expect(loaded.limits!.minRequestIntervalMs, 250);
      expect(loaded.limits!.requestsPerMinute, 30,
          reason: 'the interval write must not clobber sibling limits');
      // Absent → null (the app default of 1 request/sec applies).
      writeUserConfig(const UserConfig(), env: {}, tinaDir: tmp);
      expect(loadUserConfig(env: {}, tinaDir: tmp).limits, isNull);
    });

    test('[providers.<id>] requests_per_minute round-trips, 0 kept as-is',
        () {
      writeUserConfig(
        const UserConfig(providers: {
          'nim': ProviderConfig(requestsPerMinute: 40),
          'hetzner': ProviderConfig(requestsPerMinute: 0),
          'anthropic': ProviderConfig(apiKey: 'sk-ant-x'),
        }),
        env: {},
        tinaDir: tmp,
      );
      final loaded = loadUserConfig(env: {}, tinaDir: tmp);
      expect(loaded.providers['nim']?.requestsPerMinute, 40);
      expect(loaded.providers['hetzner']?.requestsPerMinute, 0,
          reason: '0 is meaningful (explicitly disables spacing for that '
              'provider) and must survive the round trip');
      expect(loaded.providers['anthropic']?.requestsPerMinute, isNull,
          reason: 'absent → no override: descriptor hint / global default');
      // A sibling key must survive a requests_per_minute rewrite, and vice
      // versa — both live in one [providers.<id>] table.
      writeUserConfig(
        loaded.copyWith(providers: {
          ...loaded.providers,
          'nim': const ProviderConfig(
              apiKey: 'test-key-x', requestsPerMinute: 30),
        }),
        env: {},
        tinaDir: tmp,
      );
      final reloaded = loadUserConfig(env: {}, tinaDir: tmp);
      expect(reloaded.providers['nim']?.requestsPerMinute, 30);
      expect(reloaded.providers['nim']?.apiKey, 'test-key-x');
      expect(reloaded.providers['hetzner']?.requestsPerMinute, 0,
          reason: 'the nim write must not clobber sibling providers');
    });

    test('[limits] max_concurrent_requests round-trips beside the interval',
        () {
      writeUserConfig(
        const UserConfig(
            limits:
                LimitsConfig(minRequestIntervalMs: 500, maxTurnTokens: 1000)),
        env: {},
        tinaDir: tmp,
      );
      writeUserConfig(
        loadUserConfig(env: {}, tinaDir: tmp).copyWith(
            limits: const LimitsConfig(
                minRequestIntervalMs: 500,
                maxTurnTokens: 1000,
                maxConcurrentRequests: 2)),
        env: {},
        tinaDir: tmp,
      );
      final loaded = loadUserConfig(env: {}, tinaDir: tmp);
      expect(loaded.limits!.maxConcurrentRequests, 2);
      expect(loaded.limits!.minRequestIntervalMs, 500,
          reason: 'the concurrency write must not clobber the interval');
    });

    test('parseEnvironmentAutoPopulate maps raw values', () {
      expect(parseEnvironmentAutoPopulate('always'),
          EnvironmentAutoPopulate.always);
      expect(parseEnvironmentAutoPopulate('never'),
          EnvironmentAutoPopulate.never);
      expect(parseEnvironmentAutoPopulate('ask'), EnvironmentAutoPopulate.ask);
      // Unknown / absent fall to ask (the safe default: never auto-spend).
      expect(parseEnvironmentAutoPopulate('sometimes'),
          EnvironmentAutoPopulate.ask);
      expect(parseEnvironmentAutoPopulate(null), EnvironmentAutoPopulate.ask);
    });

    test('[tui] mouse_wheel round-trips through loadUserConfig', () {
      writeUserConfig(const UserConfig(mouseWheel: false),
          env: {}, tinaDir: tmp);
      expect(loadUserConfig(env: {}, tinaDir: tmp).mouseWheel, isFalse);
      // Absent → null (the caller resolves null → true: wheel capture on).
      writeUserConfig(const UserConfig(), env: {}, tinaDir: tmp);
      expect(loadUserConfig(env: {}, tinaDir: tmp).mouseWheel, isNull);
    });

    test('copyWith patches one field without dropping the others', () {
      final base = UserConfig(
        defaultProvider: 'anthropic',
        trustDefault: 'always',
        environmentAutoPopulate: 'ask',
      );
      final patched = base.copyWith(environmentAutoPopulate: 'never');
      expect(patched.environmentAutoPopulate, 'never');
      expect(patched.defaultProvider, 'anthropic');
      expect(patched.trustDefault, 'always');
    });

    test('[theme] round-trips through loadUserConfig', () {
      const theme = Theme(
        chat: ChatTheme(userBar: '92;100'),
        border: BorderTheme(
          focus: '35',
          busy: BusyBorderTheme(
            rail: '38;2;11;22;33',
            head: '1;38;2;44;55;66',
            railRgb: [11, 22, 33],
            headRgb: [44, 55, 66],
            tailLength: 5,
          ),
        ),
      );
      writeUserConfig(
        UserConfig(theme: theme),
        env: {},
        tinaDir: tmp,
      );
      final loaded = loadUserConfig(env: {}, tinaDir: tmp);
      expect(loaded.theme, isNotNull);
      expect(loaded.theme!.chat.userBar, '92;100');
      expect(loaded.theme!.border.focus, '35');
      expect(loaded.theme!.border.busy.rail, '38;2;11;22;33');
      expect(loaded.theme!.border.busy.headRgb, [44, 55, 66]);
      expect(loaded.theme!.border.busy.tailLength, 5);
    });

    test('[theme] TOML file with chat overrides loads correctly', () {
      writeConfig('''
version = 1
[theme]
[theme.chat]
user_bar = "93;41"
agent_text = "34"
[theme.border]
focus = "32"
''');
      final c = loadUserConfig(env: {}, tinaDir: tmp);
      expect(c.theme, isNotNull);
      expect(c.theme!.chat.userBar, '93;41');
      expect(c.theme!.chat.agentText, '34');
      expect(c.theme!.border.focus, '32');
      // Defaults preserved for unset keys:
      expect(c.theme!.chat.dim, '2');
      expect(c.theme!.border.busy.rail, '38;2;30;110;130');
    });

    test('an empty theme is omitted from the written file', () {
      writeUserConfig(const UserConfig(defaultProvider: 'a', defaultModel: 'b'), env: {}, tinaDir: tmp);
      final raw = File(p.join(tmp.path, 'config')).readAsStringSync();
      expect(raw, isNot(contains('[theme')));
    });

    test('themeVariant round-trips through TOML as [theme] variant key', () {
      writeUserConfig(
        UserConfig(themeVariant: 'dark'),
        env: {},
        tinaDir: tmp,
      );
      final loaded = loadUserConfig(env: {}, tinaDir: tmp);
      expect(loaded.themeVariant, 'dark');
      final raw = File(p.join(tmp.path, 'config')).readAsStringSync();
      expect(raw, contains('[theme]'));
      // TOML variant value round-trips (the quote style is TOML-lib specific).
      expect(loaded.themeVariant, 'dark');
    });

    test('themeVariant = null omits [theme] section entirely', () {
      writeUserConfig(
        const UserConfig(defaultProvider: 'a', defaultModel: 'b'),
        env: {},
        tinaDir: tmp,
      );
      final loaded = loadUserConfig(env: {}, tinaDir: tmp);
      expect(loaded.themeVariant, isNull);
      final raw = File(p.join(tmp.path, 'config')).readAsStringSync();
      expect(raw, isNot(contains('[theme]')));
    });

    test('themeVariant coexists with explicit per-key theme overrides', () {
      const theme = Theme(chat: ChatTheme(userBar: '44;40'));
      writeUserConfig(
        const UserConfig(theme: theme, themeVariant: 'light'),
        env: {},
        tinaDir: tmp,
      );
      final loaded = loadUserConfig(env: {}, tinaDir: tmp);
      expect(loaded.themeVariant, 'light');
      expect(loaded.theme, isNotNull);
      expect(loaded.theme!.chat.userBar, '44;40');
      final raw = File(p.join(tmp.path, 'config')).readAsStringSync();
      expect(raw, contains('[theme.chat]'));
      expect(raw, contains('user_bar'));
    });

    test('UserConfig.fromMap parses variant from [theme] table', () {
      final c = UserConfig.fromMap({
        'theme': {'variant': 'light'},
      });
      expect(c.themeVariant, 'light');
      // Theme.fromMap parses the map; variant alone returns a Theme with all
      // defaults (not null).
      expect(c.theme, isNotNull);
    });

    test('userConfigToToml omits empty sections', () {
      writeUserConfig(
          const UserConfig(providers: {'a': ProviderConfig(apiKey: 'k')}),
          env: {},
          tinaDir: tmp);
      final raw = File(p.join(tmp.path, 'config')).readAsStringSync();
      expect(raw, contains('[providers'));
      expect(raw, isNot(contains('[default]')));
      expect(raw, isNot(contains('[limits]')));
    });

    test('userConfigToToml preserves special characters in a key', () {
      const key = 'sk "with" \n special';
      writeUserConfig(
        const UserConfig(providers: {'anthropic': ProviderConfig(apiKey: key)}),
        env: {},
        tinaDir: tmp,
      );
      final loaded = loadUserConfig(env: {}, tinaDir: tmp);
      expect(loaded.providers['anthropic']?.apiKey, key);
    });

    test('[regions] round-trips through loadUserConfig', () {
      writeUserConfig(
        const UserConfig(regions: RegionsConfig(model: 'deepseek/deepseek-chat')),
        env: {},
        tinaDir: tmp,
      );
      final loaded = loadUserConfig(env: {}, tinaDir: tmp);
      expect(loaded.regions?.model, 'deepseek/deepseek-chat');
    });

    test('[limits] round-trips through loadUserConfig', () {
      writeUserConfig(
        const UserConfig(limits: LimitsConfig(
          maxGlobalTokens: 12345,
          maxSubAgentTokens: 678,
          requestsPerMinute: 12,
          maxTurnTokens: 111,
          maxSessionTokens: 222,
          maxRequestTokens: 333,
        )),
        env: {},
        tinaDir: tmp,
      );
      final loaded = loadUserConfig(env: {}, tinaDir: tmp);
      expect(loaded.limits?.maxGlobalTokens, 12345);
      expect(loaded.limits?.maxSubAgentTokens, 678);
      expect(loaded.limits?.requestsPerMinute, 12);
      expect(loaded.limits?.maxTurnTokens, 111);
      expect(loaded.limits?.maxSessionTokens, 222);
      expect(loaded.limits?.maxRequestTokens, 333);
    });

    test('unknown [limits] key warns but the valid keys still load', () {
      writeConfig('''
version = 1
[limits]
max_global_tokens = 999
max_tokns = 5
''');
      final c = loadUserConfig(env: {}, tinaDir: tmp);
      expect(c.limits?.maxGlobalTokens, 999);
    });

    test('[prompts.<role>] round-trips through loadUserConfig (incl. multiline)',
        () {
      const identity = 'You are a custom main agent.\n\nBe terse.\nCite paths.';
      writeUserConfig(
        const UserConfig(prompts: {'main': identity, 'research': 'short'}),
        env: {},
        tinaDir: tmp,
      );
      final loaded = loadUserConfig(env: {}, tinaDir: tmp);
      expect(loaded.prompts, {'main': identity, 'research': 'short'});
    });

    test('an empty prompts map is omitted from the written file', () {
      writeUserConfig(const UserConfig(defaultProvider: 'a', defaultModel: 'b'), env: {}, tinaDir: tmp);
      final raw = File(p.join(tmp.path, 'config')).readAsStringSync();
      expect(raw, isNot(contains('[prompts')));
    });

    test('unknown key inside [prompts.<role>] warns but the identity loads', () {
      writeConfig('''
version = 1
[prompts.main]
identity = "kept"
identiy = "typo"
''');
      final c = loadUserConfig(env: {}, tinaDir: tmp);
      expect(c.prompts, {'main': 'kept'});
    });
  });

  group('UserConfig.fromMap version', () {
    test('absent version defaults to current', () {
      expect(UserConfig.fromMap({}).version, kCurrentConfigVersion);
    });

    test('declared version is preserved', () {
      expect(UserConfig.fromMap({'version': 2}).version, 2);
    });
  });
}
