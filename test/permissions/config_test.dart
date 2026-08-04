import 'package:tina/config.dart';
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

  group('Config polish flags', () {
    test('--max-steps defaults to 50 and accepts overrides', () {
      expect(_parse([]).maxSteps, 50);
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
