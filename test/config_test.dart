import 'package:tina/config.dart';
import 'package:tina/config/user_config.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina_console/tina_console.dart';
import 'package:test/test.dart';

import 'helpers/test_registry.dart';

/// Pins that [Config.parse] resolves the startup API key through the registry's
/// auth resolver ([ProviderRegistry.authFor]) — the single source of truth
/// shared with [ProviderRegistry.build]. Guards against Config re-inlining its
/// own env scan and the two drifting apart.
void main() {
  test('resolves the API key from the descriptor auth source env var', () {
    final cfg = Config.parse(
      const [],
      env: const {'ANTHROPIC_API_KEY': 'sk-from-env'},
      registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk-from-env'}),
    );
    expect(cfg.apiKey, 'sk-from-env');
  });

  test('prefers the first-listed auth source when both env vars are set', () {
    // Anthropic lists ANTHROPIC_AUTH_TOKEN before ANTHROPIC_API_KEY, so the
    // token wins (and resolves to Bearer at build time).
    final env = const {
      'ANTHROPIC_AUTH_TOKEN': 'tok',
      'ANTHROPIC_API_KEY': 'sk'
    };
    final cfg = Config.parse(
      const [],
      env: env,
      registry: testRegistry(env),
    );
    expect(cfg.apiKey, 'tok');
  });

  test('Config env wins even when the registry was built with a different one',
      () {
    // The registry here is built from Platform.environment, but Config's
    // injected env must drive key resolution. This is the divergence case the
    // `env` parameter on authFor exists to handle: Config and the registry may
    // legitimately hold different env maps.
    final cfg = Config.parse(
      const [],
      env: const {'ANTHROPIC_API_KEY': 'sk-from-config-env'},
      registry: builtinRegistry(),
    );
    expect(cfg.apiKey, 'sk-from-config-env');
  });

  test('a missing key returns an unconfigured Config instead of throwing', () {
    // First-run setup boots before any key is configured; Config.parse no
    // longer throws, so the app can show the setup overlay. An empty apiKey is
    // the "not configured" signal main() gates the overlay on.
    final cfg = Config.parse(
      const [],
      env: const {},
      registry: testRegistry(const {}),
      userConfig: const UserConfig(defaultProvider: 'openai'),
    );
    expect(cfg.apiKey, '');
    expect(cfg.provider, 'openai');
  });

  group('user config precedence (file > env > default)', () {
    test('[default] workflow surfaces as Config.defaultWorkflow', () {
      final cfg = Config.parse(
        const [],
        env: const {},
        registry: testRegistry(const {}),
        userConfig: const UserConfig(defaultWorkflow: 'default'),
      );
      expect(cfg.defaultWorkflow, 'default');
    });

    test('no [default] workflow means null (presence-based routing)', () {
      final cfg = Config.parse(
        const [],
        env: const {},
        registry: testRegistry(const {}),
        userConfig: const UserConfig(),
      );
      expect(cfg.defaultWorkflow, isNull);
    });

    test('file defaultProvider beats the built-in default', () {
      final cfg = Config.parse(
        const [],
        env: const {'OPENAI_API_KEY': 'sk'},
        registry: testRegistry(const {'OPENAI_API_KEY': 'sk'}),
        userConfig: const UserConfig(defaultProvider: 'openai'),
      );
      expect(cfg.provider, 'openai');
      // The file-chosen provider's key is resolved through the same auth path.
      expect(cfg.apiKey, 'sk');
    });

    test('file defaultModel beats the per-provider <PROVIDER>_MODEL env', () {
      final env = const {
        'ANTHROPIC_API_KEY': 'sk',
        'ANTHROPIC_MODEL': 'env-m',
      };
      final cfg = Config.parse(
        const [],
        env: env,
        registry: testRegistry(env),
        userConfig: const UserConfig(defaultModel: 'file-m'),
      );
      expect(cfg.model, 'file-m');
    });

    test('prompt overrides flow from [prompts.<role>] into Config', () {
      final cfg = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
        userConfig: const UserConfig(prompts: {
          'main': 'Custom main identity.',
          'research': 'Custom research identity.',
        }),
      );
      expect(cfg.promptOverrides, {
        'main': 'Custom main identity.',
        'research': 'Custom research identity.',
      });
    });

    test('prompt overrides default to empty when the file sets none', () {
      final cfg = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
        userConfig: const UserConfig(limits: LimitsConfig(maxGlobalTokens: 1)),
      );
      expect(cfg.promptOverrides, isEmpty);
    });

    test('[regions] model flows into Config.regionsModel', () {
      final cfg = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
        userConfig: const UserConfig(
            regions: RegionsConfig(model: 'deepseek/deepseek-chat')),
      );
      expect(cfg.regionsModel, 'deepseek/deepseek-chat');
    });

    test('regionsModel defaults to null when the file sets none', () {
      final cfg = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
        userConfig: const UserConfig(),
      );
      expect(cfg.regionsModel, isNull);
    });
  });

  group('[limits] precedence (CLI > file > default)', () {
    test('defaults apply when neither CLI nor file sets them', () {
      final cfg = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
      );
      expect(cfg.maxGlobalTokens, 50000000);
      expect(cfg.maxSubAgentTokens, 2000000);
      expect(cfg.requestsPerMinute, 0);
    });

    test('depth/concurrency caps default when neither CLI nor file sets them',
        () {
      final cfg = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
      );
      expect(cfg.maxSubAgentDepth, 3);
      expect(cfg.maxSubAgentConcurrency, 6);
    });

    test('CLI depth/concurrency flags override file and default', () {
      final cfg = Config.parse(
        const [
          '--max-sub-agent-depth',
          '5',
          '--max-sub-agent-concurrency',
          '2'
        ],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
        userConfig: const UserConfig(
            limits: LimitsConfig(
          maxSubAgentDepth: 9,
          maxSubAgentConcurrency: 4,
        )),
      );
      expect(cfg.maxSubAgentDepth, 5); // CLI beats file
      expect(cfg.maxSubAgentConcurrency, 2); // CLI beats file
    });

    test('file [limits] depth/concurrency beats the built-in default', () {
      final cfg = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
        userConfig: const UserConfig(
            limits: LimitsConfig(
          maxSubAgentDepth: 7,
          maxSubAgentConcurrency: 1,
        )),
      );
      expect(cfg.maxSubAgentDepth, 7);
      expect(cfg.maxSubAgentConcurrency, 1);
    });

    test('CLI --max-global-tokens beats the file beats the default', () {
      final cfg = Config.parse(
        const ['--max-global-tokens', '111'],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
        userConfig:
            const UserConfig(limits: LimitsConfig(maxGlobalTokens: 222)),
      );
      expect(cfg.maxGlobalTokens, 111);
    });

    test('file [limits] beats the built-in default', () {
      final cfg = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
        userConfig: const UserConfig(
            limits: LimitsConfig(
          maxGlobalTokens: 999,
          maxSubAgentTokens: 888,
          requestsPerMinute: 30,
        )),
      );
      expect(cfg.maxGlobalTokens, 999);
      expect(cfg.maxSubAgentTokens, 888);
      expect(cfg.requestsPerMinute, 30);
    });

    test('file value of 0 means unbounded (honored over the default)', () {
      final cfg = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
        userConfig: const UserConfig(limits: LimitsConfig(maxGlobalTokens: 0)),
      );
      expect(cfg.maxGlobalTokens, 0,
          reason: 'an explicit 0 in the file is "unbounded", not "absent"');
    });

    test('a negative CLI value throws', () {
      expect(
          () => Config.parse(
                const ['--max-global-tokens', '-5'],
                env: const {'ANTHROPIC_API_KEY': 'sk'},
                registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
              ),
          throwsA(isA<FormatException>()));
    });

    test('buildSubAgentBudget: null when 0, else a per-session budget', () {
      final off = Config.parse(
        const ['--max-sub-agent-tokens', '0'],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
      );
      expect(off.buildSubAgentBudget(), isNull);

      final on = Config.parse(
        const ['--max-sub-agent-tokens', '5000'],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
      );
      final budget = on.buildSubAgentBudget();
      expect(budget, isNotNull);
      expect(budget!.perSessionLimit, 5000);
      expect(budget.perTurnLimit, isNull);
      expect(budget.perRequestInputLimit, isNull);
    });

    test('main-agent budgets: file [limits] beats the built-in default', () {
      final cfg = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
        userConfig: const UserConfig(
            limits: LimitsConfig(
          maxTurnTokens: 7,
          maxSessionTokens: 8,
          maxRequestTokens: 9,
        )),
      );
      expect(cfg.maxTurnTokens, 7);
      expect(cfg.maxSessionTokens, 8);
      expect(cfg.maxRequestTokens, 9);
    });

    test('main-agent budgets: CLI beats file', () {
      final cfg = Config.parse(
        const [
          '--max-turn-tokens',
          '5',
          '--max-session-tokens',
          '6',
        ],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
        userConfig: const UserConfig(
            limits: LimitsConfig(maxTurnTokens: 7, maxSessionTokens: 8)),
      );
      expect(cfg.maxTurnTokens, 5);
      expect(cfg.maxSessionTokens, 6);
    });

    test('main-agent budgets: file 0 means unbounded (honored over default)',
        () {
      final cfg = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
        userConfig: const UserConfig(limits: LimitsConfig(maxSessionTokens: 0)),
      );
      expect(cfg.maxSessionTokens, 0,
          reason: 'an explicit 0 in the file disables the cap, not "absent"');
    });
  });

  group('--safe-mode flag', () {
    test('safeMode defaults to false when the flag is absent', () {
      final cfg = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
      );
      expect(cfg.safeMode, isFalse);
    });

    test('--safe-mode sets safeMode to true', () {
      final cfg = Config.parse(
        const ['--safe-mode'],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
      );
      expect(cfg.safeMode, isTrue);
    });

    test('--safe-mode combined with --yolo still yields safeMode', () {
      final cfg = Config.parse(
        const ['--safe-mode', '--yolo'],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
      );
      expect(cfg.safeMode, isTrue);
      expect(cfg.yolo, isTrue);
    });
  });

  group('[theme] carries through to Config', () {
    test('file [theme] flows into Config.theme', () {
      const theme = Theme(chat: ChatTheme(userBar: '92;100'));
      final cfg = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
        userConfig: const UserConfig(theme: theme),
      );
      expect(cfg.theme.chat.userBar, '92;100');
    });

    test('defaults to the shipped theme when the file has none', () {
      final cfg = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'sk'},
        registry: testRegistry(const {'ANTHROPIC_API_KEY': 'sk'}),
        userConfig: const UserConfig(limits: LimitsConfig(maxGlobalTokens: 1)),
      );
      expect(cfg.theme.chat.userBar, '7');
      expect(cfg.theme.border.focus, '36');
    });
  });
}
