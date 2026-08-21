import 'package:tina/config.dart';
import 'package:tina/config/user_config.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('Config permission flags', () {
    test('--allow and --deny populate permissionRules; deny is listed first',
        () {
      final c = _parse(['--allow', 'bash:git *', '--deny', 'bash:rm *']);
      expect(c.permissionRules.length, 2);
      expect(c.permissionRules.first.decision, PermissionDecision.deny);
      expect(c.permissionRules.first.pattern, 'rm *');
      expect(c.permissionRules.last.decision, PermissionDecision.allow);
    });

    test('--yolo flips defaults to allow; explicit --deny still wins', () {
      final c = _parse(['--yolo', '--deny', 'bash:rm *']);
      final p = c.buildPolicy();
      expect(p.check('bash', {'command': 'ls'}), PermissionDecision.allow);
      expect(p.check('write', {'filePath': '/x'}), PermissionDecision.allow);
      expect(p.check('bash', {'command': 'rm -rf /'}),
          PermissionDecision.deny);
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
      expect(
          () => _parse(['--allow', 'bashgit *']), throwsFormatException);
    });
  });

  group('--permission-mode', () {
    test('defaults to ask when neither flag nor file sets it', () {
      expect(_parse([]).permissionMode, PermissionMode.ask);
    });

    test('the flag selects each mode', () {
      expect(_parse(['--permission-mode', 'read-all']).permissionMode,
          PermissionMode.readAll);
      expect(_parse(['--permission-mode', 'allow-edits']).permissionMode,
          PermissionMode.allowEdits);
      expect(_parse(['--permission-mode', 'auto']).permissionMode,
          PermissionMode.auto);
      expect(_parse(['--permission-mode', 'ask']).permissionMode,
          PermissionMode.ask);
    });

    test('an unknown mode value fails fast', () {
      expect(() => _parse(['--permission-mode', 'yolo-mode']),
          throwsFormatException);
    });

    test('the flag beats the [permissions] mode file value', () {
      final c = Config.parse(
        const ['--permission-mode', 'read-all'],
        env: const {'ANTHROPIC_API_KEY': 'test'},
        userConfig: const UserConfig(
            permissions: PermissionsConfig(mode: 'auto')),
      );
      expect(c.permissionMode, PermissionMode.readAll);
    });

    test('the [permissions] mode/model file values flow into Config', () {
      final c = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'test'},
        userConfig: const UserConfig(
            permissions:
                PermissionsConfig(mode: 'allow_edits', model: 'nim/foo')),
      );
      expect(c.permissionMode, PermissionMode.allowEdits);
      expect(c.permissionClassifierModel, 'nim/foo');
    });

    test('an unknown file mode value degrades to ask, not a crash', () {
      final c = Config.parse(
        const [],
        env: const {'ANTHROPIC_API_KEY': 'test'},
        userConfig:
            const UserConfig(permissions: PermissionsConfig(mode: 'nope')),
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

    test('--max-steps defaults to 500 and accepts overrides', () {
      expect(_parse([]).maxSteps, 500);
      expect(_parse(['--max-steps', '200']).maxSteps, 200);
    });

    test('--max-steps rejects zero and negative', () {
      expect(() => _parse(['--max-steps', '0']), throwsFormatException);
      expect(() => _parse(['--max-steps', '-1']), throwsFormatException);
    });

    test('--stream-idle-timeout defaults to 60s', () {
      expect(_parse([]).streamIdleTimeout, const Duration(seconds: 60));
      expect(_parse(['--stream-idle-timeout', '5']).streamIdleTimeout,
          const Duration(seconds: 5));
    });

    test('--auto-compact-threshold defaults to 120000; 0 disables; overrides', () {
      expect(_parse([]).autoCompactThreshold, 120000);
      expect(_parse(['--auto-compact-threshold', '0']).autoCompactThreshold, 0);
      expect(_parse(['--auto-compact-threshold', '50000']).autoCompactThreshold,
          50000);
    });

    test('--auto-compact-threshold rejects negative and non-integer', () {
      expect(() => _parse(['--auto-compact-threshold', '-1']),
          throwsFormatException);
      expect(() => _parse(['--auto-compact-threshold', 'abc']),
          throwsFormatException);
    });
  });
}

Config _parse(List<String> argv) =>
    Config.parse(argv, env: const {'ANTHROPIC_API_KEY': 'test'});
