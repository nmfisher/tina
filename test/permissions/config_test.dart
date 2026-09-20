import 'package:tina/config.dart';
import 'package:tina/config/user_config.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('Config permission flags', () {
    test(
      '--allow and --deny populate permissionRules; deny is listed first',
      () {
        final c = _parse(['--allow', 'bash:git *', '--deny', 'bash:rm *']);
        expect(c.permissionRules.length, 2);
        expect(c.permissionRules.first.decision, PermissionDecision.deny);
        expect(c.permissionRules.first.pattern, 'rm *');
        expect(c.permissionRules.last.decision, PermissionDecision.allow);
      },
    );

    test('--yolo flips defaults to allow; explicit --deny still wins', () {
      final c = _parse(['--yolo', '--deny', 'bash:rm *']);
      final p = c.buildPolicy();
      expect(p.check('bash', {'command': 'ls'}), PermissionDecision.allow);
      expect(p.check('write', {'filePath': '/x'}), PermissionDecision.allow);
      expect(p.check('bash', {'command': 'rm -rf /'}), PermissionDecision.deny);
    });

    test('without --yolo, defaults are ask except read', () {
      final c = _parse([]);
      final p = c.buildPolicy();
      expect(p.check('read', {'filePath': '/x'}), PermissionDecision.allow);
      expect(p.check('write', {'filePath': '/x'}), PermissionDecision.ask);
      expect(p.check('edit', {'filePath': '/x'}), PermissionDecision.ask);
      expect(p.check('bash', {'command': 'ls'}), PermissionDecision.ask);
    });

    test('malformed rule fails fast', () {
      expect(() => _parse(['--allow', 'bashgit *']), throwsFormatException);
    });
  });

  group('--permission-mode', () {
    test('defaults to ask when neither flag nor file sets it', () {
      expect(_parse([]).permissionMode, PermissionMode.ask);
    });

    test('the flag selects each mode', () {
      expect(
        _parse(['--permission-mode', 'read-all']).permissionMode,
        PermissionMode.readAll,
      );
      expect(
        _parse(['--permission-mode', 'allow-edits']).permissionMode,
        PermissionMode.allowEdits,
      );
      expect(
        _parse(['--permission-mode', 'auto']).permissionMode,
        PermissionMode.auto,
      );
      expect(
        _parse(['--permission-mode', 'ask']).permissionMode,
        PermissionMode.ask,
      );
    });

    test('an unknown mode value fails fast', () {
      expect(
        () => _parse(['--permission-mode', 'yolo-mode']),
        throwsFormatException,
      );
    });

    test('the flag beats the [permissions] mode file value', () {
      final c = Config.parse(
        const ['--permission-mode', 'read-all'],
        env: const {'ANTHROPIC_API_KEY': 'test'},
        userConfig: const UserConfig(
          permissions: PermissionsConfig(mode: 'auto'),
        ),
      );
      expect(c.permissionMode, PermissionMode.readAll);
    });

    test('the [permissions] mode/model file values flow into Config', () {
      final c = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'test'},
        userConfig: const UserConfig(
          permissions: PermissionsConfig(mode: 'allow_edits', model: 'nim/foo'),
        ),
      );
      expect(c.permissionMode, PermissionMode.allowEdits);
      expect(c.permissionClassifierModel, 'nim/foo');
    });

    test('an unknown file mode value degrades to ask, not a crash', () {
      final c = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'test'},
        userConfig: const UserConfig(
          permissions: PermissionsConfig(mode: 'nope'),
        ),
      );
      expect(c.permissionMode, PermissionMode.ask);
    });

    test('buildPolicy carries the mode', () {
      final p = _parse(['--permission-mode', 'allow-edits']).buildPolicy();
      expect(p.mode, PermissionMode.allowEdits);
      expect(p.check('edit', {'filePath': '/x'}), PermissionDecision.allow);
      expect(p.check('bash', {'command': 'ls'}), PermissionDecision.ask);
    });
  });

  group('Config polish flags', () {
    test('--no-sandbox disables the bash write-sandbox (on by default)', () {
      expect(_parse([]).sandboxEnabled, isTrue);
      expect(_parse(['--no-sandbox']).sandboxEnabled, isFalse);
    });

    test('sandbox precedence: explicit flag > --yolo > defaults (tin-y9k2)',
        () {
      // Default: sandbox on, no off-reason.
      final plain = _parse([]);
      expect(plain.sandboxEnabled, isTrue);
      expect(plain.sandboxOffReason, isNull);

      // --yolo alone turns the sandbox OFF and says why.
      final yolo = _parse(['--yolo']);
      expect(yolo.sandboxEnabled, isFalse);
      expect(yolo.sandboxOffReason, contains('--yolo'));

      // --yolo --sandbox: explicit flag beats yolo — sandbox stays ON.
      final yoloSandbox = _parse(['--yolo', '--sandbox']);
      expect(yoloSandbox.sandboxEnabled, isTrue);
      expect(yoloSandbox.sandboxOffReason, isNull);

      // --no-sandbox keeps the explicit wording; yolo does not rewrite it.
      final explicitOff = _parse(['--no-sandbox']);
      expect(explicitOff.sandboxEnabled, isFalse);
      expect(explicitOff.sandboxOffReason, contains('--no-sandbox'));
      final bothOff = _parse(['--yolo', '--no-sandbox']);
      expect(bothOff.sandboxEnabled, isFalse);
      expect(bothOff.sandboxOffReason, contains('--no-sandbox'));
    });

    test('--sandbox-net / --sandbox-readonly default off, flags turn them on',
        () {
      expect(_parse([]).sandboxNet, isFalse);
      expect(_parse([]).sandboxReadOnly, isFalse);
      expect(_parse(['--sandbox-net']).sandboxNet, isTrue);
      expect(_parse(['--sandbox-readonly']).sandboxReadOnly, isTrue);
      // They compose with each other and with --no-sandbox (which wins for
      // the runner: disabled is disabled).
      final both = _parse(['--sandbox-net', '--sandbox-readonly']);
      expect(both.sandboxNet, isTrue);
      expect(both.sandboxReadOnly, isTrue);
      final off = _parse(['--no-sandbox', '--sandbox-net']);
      expect(off.sandboxEnabled, isFalse);
      expect(off.sandboxNet, isTrue);
    });

    test('--max-steps defaults to 500 and accepts overrides', () {
      expect(_parse([]).maxSteps, 500);
      expect(_parse(['--max-steps', '200']).maxSteps, 200);
    });

    test('--max-steps rejects negatives only; 0 = unbounded (tin-y9k2)', () {
      expect(_parse([]).maxSteps, 500);
      expect(_parse(['--max-steps', '200']).maxSteps, 200);
      expect(_parse(['--max-steps', '0']).maxSteps, 0);
      expect(() => _parse(['--max-steps', '-1']), throwsFormatException);
    });

    test('without --yolo, every budget keeps its default (regression)', () {
      final c = _parse([]);
      expect(c.sandboxEnabled, isTrue);
      expect(c.maxTurnTokens, 1000000);
      expect(c.maxSessionTokens, 10000000);
      expect(c.maxRequestTokens, 200000);
      expect(c.maxGlobalTokens, 50000000);
      expect(c.maxSubAgentTokens, 2000000);
      expect(c.maxSubAgentDepth, 3);
      expect(c.maxSubAgentConcurrency, 6);
      expect(c.requestsPerMinute, 0); // rpm off by default, not a yolo value
      expect(c.maxSteps, 500);
    });

    test('--yolo lifts every budget; an explicit flag still wins (tin-y9k2)',
        () {
      final c = _parse(['--yolo']);
      expect(c.sandboxEnabled, isFalse);
      expect(c.maxTurnTokens, 0);
      expect(c.maxSessionTokens, 0);
      expect(c.maxRequestTokens, 0);
      expect(c.maxGlobalTokens, 0);
      expect(c.maxSubAgentTokens, 0);
      expect(c.maxSubAgentDepth, 0);
      expect(c.maxSubAgentConcurrency, 0);
      expect(c.maxSteps, 0);

      // Explicit flag > --yolo: a bounded yolo run stays bounded.
      final bounded = _parse(['--yolo', '--max-steps', '50']);
      expect(bounded.maxSteps, 50);
      expect(
        _parse(['--yolo', '--max-turn-tokens', '500000']).maxTurnTokens,
        500000,
      );

      // Config-file values are ignored under --yolo (file < yolo)...
      final withFile = Config.parse(
        const ['--yolo'],
        env: const {'ANTHROPIC_API_KEY': 'test'},
        userConfig: const UserConfig(
          limits: LimitsConfig(maxTurnTokens: 250000),
        ),
      );
      expect(withFile.maxTurnTokens, 0);
      // ...and still honored without it (file < default? no: file > default).
      final noYoloFile = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'test'},
        userConfig: const UserConfig(
          limits: LimitsConfig(maxTurnTokens: 250000),
        ),
      );
      expect(noYoloFile.maxTurnTokens, 250000);
    });

    test('--watchdog-seconds defaults to 300; overrides and 0 kept', () {
      expect(_parse([]).watchdogSeconds, 300);
      expect(_parse(['--watchdog-seconds', '5']).watchdogSeconds, 5);
      // 0 is the explicit "disable the watchdog" value, not an error.
      expect(_parse(['--watchdog-seconds', '0']).watchdogSeconds, 0);
    });

    test('--watchdog-seconds rejects negative and non-integer', () {
      expect(() => _parse(['--watchdog-seconds', '-1']), throwsFormatException);
      expect(
        () => _parse(['--watchdog-seconds', 'abc']),
        throwsFormatException,
      );
    });

    test('--stream-idle-timeout defaults to 60s', () {
      expect(_parse([]).streamIdleTimeout, const Duration(seconds: 60));
      expect(
        _parse(['--stream-idle-timeout', '5']).streamIdleTimeout,
        const Duration(seconds: 5),
      );
    });

    test(
      '--auto-compact-threshold defaults to 120000; 0 disables; overrides',
      () {
        expect(_parse([]).autoCompactThreshold, 120000);
        expect(
          _parse(['--auto-compact-threshold', '0']).autoCompactThreshold,
          0,
        );
        expect(
          _parse(['--auto-compact-threshold', '50000']).autoCompactThreshold,
          50000,
        );
      },
    );

    test('--auto-compact-threshold rejects negative and non-integer', () {
      expect(
        () => _parse(['--auto-compact-threshold', '-1']),
        throwsFormatException,
      );
      expect(
        () => _parse(['--auto-compact-threshold', 'abc']),
        throwsFormatException,
      );
    });

    test('--model bare value overrides the model, provider unchanged', () {
      final c = _parse(['--model', 'glimmer-30b']);
      expect(c.model, 'glimmer-30b');
      expect(c.provider, 'anthropic');
    });

    test('--model full ref splits on the FIRST slash only', () {
      final c = _parse(['--model', 'openrouter/stealth/ox-alpha']);
      expect(c.provider, 'openrouter');
      // Model ids may themselves contain slashes — the remainder after the
      // first '/' is the model, slashes kept.
      expect(c.model, 'stealth/ox-alpha');
    });

    test('--model beats the [default] provider/model file values', () {
      // Full ref: both provider and model come from the flag.
      final full = Config.parse(
        const ['--model', 'openrouter/stealth/ox-alpha'],
        env: const {'ANTHROPIC_API_KEY': 'test'},
        userConfig: const UserConfig(
          defaultProvider: 'anthropic',
          defaultModel: 'claude-file',
        ),
      );
      expect(full.provider, 'openrouter');
      expect(full.model, 'stealth/ox-alpha');
      // Bare form: the model wins, the file provider is kept.
      final bare = Config.parse(
        const ['--model', 'glimmer-30b'],
        env: const {'ANTHROPIC_API_KEY': 'test'},
        userConfig: const UserConfig(
          defaultProvider: 'anthropic',
          defaultModel: 'claude-file',
        ),
      );
      expect(bare.provider, 'anthropic');
      expect(bare.model, 'glimmer-30b');
    });

    test('without --model, the [default] model file value is honored', () {
      final c = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'test'},
        userConfig: const UserConfig(defaultModel: 'claude-file'),
      );
      expect(c.provider, 'anthropic');
      expect(c.model, 'claude-file');
    });

    test('--model full ref with an unknown provider fails fast', () {
      expect(
        () => _parse(['--model', 'nosuchprovider/some-model']),
        throwsFormatException,
      );
    });
  });

  group('Config modelExplicit', () {
    test('--model bare value marks the flag explicit', () {
      expect(_parse(['--model', 'glimmer-30b']).modelExplicit, isTrue);
    });

    test('--model full ref marks the flag explicit', () {
      expect(
        _parse(['--model', 'openrouter/stealth/ox-alpha']).modelExplicit,
        isTrue,
      );
    });

    test('without --model, modelExplicit is false (resume may honor the '
        'persisted conversation model)', () {
      expect(_parse([]).modelExplicit, isFalse);
    });
  });

  group('--transport-retry-attempts', () {
    test('defaults to 5 (headless opt-in per #28)', () {
      expect(_parse([]).transportRetryAttempts, 5);
    });

    test('accepts overrides and keeps 0 as the explicit off', () {
      expect(_parse(['--transport-retry-attempts', '3'])
          .transportRetryAttempts, 3);
      expect(_parse(['--transport-retry-attempts', '0'])
          .transportRetryAttempts, 0,
          reason: '0 disables the ladder — abort on first mid-stream error');
    });

    test('rejects negative and non-integer', () {
      expect(
        () => _parse(['--transport-retry-attempts', '-1']),
        throwsFormatException,
      );
      expect(
        () => _parse(['--transport-retry-attempts', 'abc']),
        throwsFormatException,
      );
    });
  });
}

Config _parse(List<String> argv) =>
    Config.parse(argv, env: const {'ANTHROPIC_API_KEY': 'test'});
