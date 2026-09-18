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
    test('bash uses the exact command (not first word + " *")', () {
      // Approving a bash command re-approves only THAT command, so a single
      // `rm -rf /tmp/junk` okay does not silently widen to all `rm` calls.
      expect(
          PermissionPolicy.defaultAlwaysPatternFor(
              'bash', {'command': 'git status --short'}),
          'git status --short');
      expect(
          PermissionPolicy.defaultAlwaysPatternFor(
              'bash', {'command': '   ls -la'}),
          'ls -la');
      expect(
          PermissionPolicy.defaultAlwaysPatternFor(
              'bash', {'command': 'rm -rf /tmp/junk'}),
          'rm -rf /tmp/junk');
    });

    test('an exact bash pattern does not match a different command', () {
      final p = PermissionPolicy(rules: const [
        PermissionRule(
            toolName: 'bash',
            pattern: 'git status --short',
            decision: PermissionDecision.allow),
      ]);
      expect(p.check('bash', {'command': 'git status --short'}),
          PermissionDecision.allow);
      // A different `git` invocation must NOT inherit the literal approval.
      expect(p.check('bash', {'command': 'git push --force'}),
          PermissionDecision.ask);
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

  group('keyFor', () {
    test('launch_workflow keys on the workflow name (defaulted)', () {
      expect(PermissionPolicy.keyFor('launch_workflow', {'input': 'x'}),
          'default');
      expect(PermissionPolicy.keyFor(
          'launch_workflow', {'input': 'x', 'workflow': 'lint'}), 'lint');
      expect(PermissionPolicy.keyFor(
          'launch_workflow', {'input': 'x', 'workflow': '   '}), 'default');
    });

    test('bash and file tools keep their keys', () {
      expect(PermissionPolicy.keyFor('bash', {'command': 'ls'}), 'ls');
      expect(PermissionPolicy.keyFor('read', {'filePath': '/a/b'}), '/a/b');
    });
  });

  group('PermissionPolicy.allowedPatterns', () {
    test('lists only allow decisions for the tool, static then session', () {
      final p = PermissionPolicy(rules: const [
        PermissionRule(
            toolName: 'bash',
            pattern: 'git *',
            decision: PermissionDecision.allow),
        PermissionRule(
            toolName: 'bash',
            pattern: 'rm *',
            decision: PermissionDecision.deny),
        PermissionRule(
            toolName: 'write',
            pattern: '/tmp/*',
            decision: PermissionDecision.allow),
      ]);
      p.remember('bash', 'dart *', PermissionDecision.allow);

      expect(
          p.allowedPatterns('bash'),
          ['bash:git *', 'bash:dart *'],
          reason: 'deny rules and other tools are excluded');
      expect(p.allowedPatterns('write'), ['write:/tmp/*']);
    });

    test('a wildcard-tool rule counts for every tool, deduped', () {
      final p = PermissionPolicy(rules: const [
        PermissionRule(
            toolName: '*',
            pattern: '/data/**',
            decision: PermissionDecision.allow),
      ]);
      p.remember('read', '/data/**', PermissionDecision.allow);

      expect(p.allowedPatterns('read'), ['read:/data/**'],
          reason: 'the same effective rule from two sources is listed once');
      expect(p.allowedPatterns('write'), ['write:/data/**']);
    });

    test('empty when the tool has no allow rules', () {
      final p = PermissionPolicy();
      expect(p.allowedPatterns('bash'), isEmpty);
    });
  });

  group('PermissionPolicy.targetFor', () {
    // The one chain the prompt, the remembered rule and rule matching all read.
    ApprovalTarget target(String tool, Map<String, dynamic> input) =>
        PermissionPolicy.targetFor(tool, input);

    test('bash is its exact command, environment and all', () {
      final t = target('bash', {'command': '  git status --short '});
      expect(t.label, 'git status --short');
      expect(t.remember, 'git status --short');
      expect(t.invocation, isFalse);
    });

    test('a custom environment makes the whole invocation the identity', () {
      final t = target('bash', {
        'command': 'dart test',
        'cwd': '/p',
        'environment': {'CI': '1'},
      });
      expect(t.invocation, isTrue);
      expect(t.label, contains('"dart test"'));
      expect(t.label, contains('"CI":"1"'));
      expect(t.remember, t.label);
    });

    test('exec keys on executable, arguments, cwd and environment', () {
      final t = target('exec', {
        'executable': 'dart',
        'args': ['test'],
        'cwd': '/p',
      });
      expect(t.invocation, isTrue);
      expect(t.label, '["dart",["test"],"/p",{}]');
      expect(t.remember, t.label);
    });

    test('a rule on exec can match an invocation containing slashes', () {
      // `*` spans `/` for an invocation, so `exec:*` is not inert. Before the
      // target owned this, `*` stopped at `/` and the JSON label (which always
      // carries a cwd) never matched it.
      final p = PermissionPolicy(rules: const [
        PermissionRule(
            toolName: 'exec', pattern: '*', decision: PermissionDecision.deny),
      ]);
      expect(
          p.check('exec', {'executable': 'dart', 'cwd': '/home/x/p'}),
          PermissionDecision.deny);
    });

    test('file tools remember the directory, root-level files exactly', () {
      final edit = target('edit', {'filePath': '/workspace/lib/foo.dart'});
      expect(edit.label, '/workspace/lib/foo.dart');
      expect(edit.remember, '/workspace/lib/*');

      final root = target('write', {'filePath': '/foo.txt'});
      expect(root.label, '/foo.txt');
      expect(root.remember, '/foo.txt',
          reason: 'a directory rule here would be the wildcard, which cannot '
              'match an absolute single-segment path');
    });

    test('a url is shown and remembered as itself', () {
      final t = target('fetch', {'url': 'https://example.com/a/b?q=1'});
      expect(t.label, 'https://example.com/a/b?q=1');
      expect(t.remember, t.label);
      expect(t.starMatchesSlash, isTrue,
          reason: 'a url is mostly slashes; `*` must span them');
    });

    test('network and region tools name their target instead of nothing', () {
      expect(target('web_search', {'query': 'dart globs'}).label, 'dart globs');
      expect(target('broadcast_region', {'task': 'what is this?'}).label,
          'what is this?');
      expect(target('forget_region', {'dir': 'lib/tui'}).label, 'lib/tui');
    });

    test('a workflow remembers the workflow, not every workflow', () {
      final t = target('launch_workflow', {'workflow': ' lint ', 'input': 'x'});
      expect(t.label, 'lint');
      expect(t.remember, 'lint');
      expect(t.remember, isNot('*'));
    });

    test('an input with nothing to point at is the fail-closed default', () {
      final t = target('mystery', const {});
      expect(t.label, isEmpty);
      expect(t.remember, '*');
      expect(t, same(ApprovalTarget.unknown));
    });

    test('keyFor and defaultAlwaysPatternFor read from the target', () {
      for (final entry in const [
        ('bash', {'command': 'ls -la'}),
        ('write', {'filePath': '/p/a/b.dart'}),
        ('fetch', {'url': 'https://example.com/x'}),
        ('launch_workflow', {'workflow': 'lint'}),
      ]) {
        final (tool, input) = entry;
        expect(PermissionPolicy.keyFor(tool, input),
            PermissionPolicy.targetFor(tool, input).label);
        expect(PermissionPolicy.defaultAlwaysPatternFor(tool, input),
            PermissionPolicy.targetFor(tool, input).remember);
      }
    });
  });

  group('PermissionPolicy.inertRules', () {
    test('reports a static rule for a tool that is not mounted', () {
      final p = PermissionPolicy(rules: const [
        PermissionRule(
            toolName: 'bashh',
            pattern: 'rm *',
            decision: PermissionDecision.deny),
      ]);
      expect(
          p.inertRules(['bash', 'read']).map((r) => '${r.toolName}:${r.pattern}'),
          ['bashh:rm *'],
          reason: 'a typo would otherwise deny nothing, silently');
    });

    test('a mounted tool and a wildcard rule are never reported', () {
      final p = PermissionPolicy(rules: const [
        PermissionRule(
            toolName: 'bash', pattern: 'rm *', decision: PermissionDecision.deny),
        PermissionRule(
            toolName: '*', pattern: '/secrets/**', decision: PermissionDecision.deny),
      ]);
      expect(p.inertRules(['bash', 'read']), isEmpty);
    });

    test('session rules are not reported (they are not configured by hand)',
        () {
      final p = PermissionPolicy();
      p.remember('bash', 'git status', PermissionDecision.allow);
      expect(p.inertRules(const <String>[]), isEmpty);
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

    test('read-only tools default to allow (no approval spam)', () {
      final p = PermissionPolicy();
      for (final tool in ['search', 'grep', 'glob', 'ls', 'stat', 'which']) {
        expect(p.check(tool, const {}), PermissionDecision.allow,
            reason: '$tool should default to allow');
      }
      // A session rule can still deny a read-only tool.
      p.remember('ls', '*', PermissionDecision.deny);
      expect(p.check('ls', const {}), PermissionDecision.deny);
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
