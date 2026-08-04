import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('globMatch', () {
    test('literal strings', () {
      expect(globMatch('git status', 'git status'), isTrue);
      expect(globMatch('git status', 'git status --short'), isFalse);
    });

    test('* does not cross /', () {
      expect(globMatch('/tmp/*.txt', '/tmp/foo.txt'), isTrue);
      expect(globMatch('/tmp/*.txt', '/tmp/sub/foo.txt'), isFalse);
    });

    test('** crosses /', () {
      expect(globMatch('/workspace/**', '/workspace/a/b/c.dart'), isTrue);
      expect(globMatch('/workspace/**', '/elsewhere/x'), isFalse);
    });

    test('escapes regex metachars', () {
      expect(globMatch(r'foo.bar', 'foo.bar'), isTrue);
      // The dot must not act as "any char" — only literal `.`.
      expect(globMatch(r'foo.bar', 'fooXbar'), isFalse);
      expect(globMatch(r'a+b', 'a+b'), isTrue);
      expect(globMatch(r'(x)', '(x)'), isTrue);
    });

    test('star alone matches bash arg tails', () {
      expect(globMatch('git *', 'git status'), isTrue);
      expect(globMatch('git *', 'git log --oneline'), isTrue);
      expect(globMatch('git *', 'gitk'), isFalse);
    });

    test('starMatchesSlash crosses slashes (bash mode)', () {
      expect(globMatch('rm *', 'rm -rf /tmp', starMatchesSlash: true),
          isTrue);
      expect(globMatch('rm *', 'rm -rf /tmp'), isFalse);
    });
  });

  group('parsePermissionRule', () {
    test('splits TOOL:PATTERN', () {
      final r = parsePermissionRule('bash:git *', PermissionDecision.allow);
      expect(r.toolName, 'bash');
      expect(r.pattern, 'git *');
      expect(r.decision, PermissionDecision.allow);
    });

    test('keeps colons inside the pattern', () {
      final r = parsePermissionRule(
          'bash:curl https://example.com', PermissionDecision.allow);
      expect(r.pattern, 'curl https://example.com');
    });

    test('rejects missing pattern', () {
      expect(() => parsePermissionRule('bash:', PermissionDecision.allow),
          throwsFormatException);
      expect(() => parsePermissionRule(':git *', PermissionDecision.allow),
          throwsFormatException);
      expect(() => parsePermissionRule('bashgit', PermissionDecision.allow),
          throwsFormatException);
    });
  });

  group('defaultAlwaysPatternFor', () {
    test('bash uses first word + " *"', () {
      expect(
          PermissionPolicy.defaultAlwaysPatternFor(
              'bash', {'command': 'git status --short'}),
          'git *');
      expect(
          PermissionPolicy.defaultAlwaysPatternFor(
              'bash', {'command': '   ls -la'}),
          'ls *');
    });

    test('file tools use dirname/*', () {
      expect(
          PermissionPolicy.defaultAlwaysPatternFor(
              'edit', {'filePath': '/workspace/lib/foo.dart'}),
          '/workspace/lib/*');
      expect(
          PermissionPolicy.defaultAlwaysPatternFor(
              'write', {'filePath': '/tmp/out.txt'}),
          '/tmp/*');
    });

    test('falls back to *', () {
      expect(
          PermissionPolicy.defaultAlwaysPatternFor('bash', {'command': ''}),
          '*');
      expect(
          PermissionPolicy.defaultAlwaysPatternFor('read', {'filePath': ''}),
          '*');
    });
  });

  group('PermissionPolicy.check', () {
    test('built-in defaults', () {
      final p = PermissionPolicy();
      expect(p.check('read', {'filePath': '/a'}), PermissionDecision.allow);
      expect(p.check('write', {'filePath': '/a'}), PermissionDecision.ask);
      expect(p.check('edit', {'filePath': '/a'}), PermissionDecision.ask);
      expect(p.check('bash', {'command': 'ls'}), PermissionDecision.ask);
    });

    test('static rules override defaults', () {
      final p = PermissionPolicy(rules: const [
        PermissionRule(
            toolName: 'bash',
            pattern: 'git *',
            decision: PermissionDecision.allow),
      ]);
      expect(p.check('bash', {'command': 'git status'}),
          PermissionDecision.allow);
      expect(p.check('bash', {'command': 'rm -rf'}), PermissionDecision.ask);
    });

    test('static deny beats static allow when listed first', () {
      // Config layers deny rules before allow rules — first-match wins.
      final p = PermissionPolicy(rules: const [
        PermissionRule(
            toolName: 'bash',
            pattern: 'rm *',
            decision: PermissionDecision.deny),
        PermissionRule(
            toolName: 'bash',
            pattern: '*',
            decision: PermissionDecision.allow),
      ]);
      expect(p.check('bash', {'command': 'rm -rf /tmp'}),
          PermissionDecision.deny);
      expect(
          p.check('bash', {'command': 'echo hi'}), PermissionDecision.allow);
    });

    test('session memory overrides static rules', () {
      final p = PermissionPolicy(rules: const [
        PermissionRule(
            toolName: 'bash',
            pattern: 'git *',
            decision: PermissionDecision.deny),
      ]);
      expect(p.check('bash', {'command': 'git status'}),
          PermissionDecision.deny);
      p.remember('bash', 'git *', PermissionDecision.allow);
      expect(p.check('bash', {'command': 'git status'}),
          PermissionDecision.allow);
    });

    test('latest session entry wins', () {
      final p = PermissionPolicy();
      p.remember('write', '/tmp/*', PermissionDecision.allow);
      p.remember('write', '/tmp/*', PermissionDecision.deny);
      expect(p.check('write', {'filePath': '/tmp/x.txt'}),
          PermissionDecision.deny);
    });

    test('wildcard tool name matches any', () {
      final p = PermissionPolicy(rules: const [
        PermissionRule(
            toolName: '*',
            pattern: '/secrets/**',
            decision: PermissionDecision.deny),
      ]);
      expect(p.check('read', {'filePath': '/secrets/db.env'}),
          PermissionDecision.deny);
      expect(p.check('write', {'filePath': '/secrets/db.env'}),
          PermissionDecision.deny);
      expect(p.check('read', {'filePath': '/elsewhere/x'}),
          PermissionDecision.allow);
    });
  });
}
