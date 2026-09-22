import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

void main() {
  PermissionRule allow(String spec) =>
      parsePermissionRule(spec, PermissionDecision.allow, regex: true);

  test('regex matches the whole target with alternation and character classes',
      () {
    final policy = PermissionPolicy(rules: [
      allow(r'bash:git (status|diff)( --[a-z]+)?'),
    ]);
    for (final command in ['git status', 'git diff', 'git diff --stat']) {
      expect(
          policy.check('bash', {'command': command}), PermissionDecision.allow);
    }
    for (final command in [
      'echo git status',
      'git status; rm file',
      'git status\ngit push',
      'git push',
      'git diff --123',
    ]) {
      expect(
          policy.check('bash', {'command': command}), PermissionDecision.ask);
    }
    expect(policy.check('other', {'filePath': 'git status'}),
        PermissionDecision.ask);
    expect(policy.staticRules.single.toString(), contains('(regex)'));
    expect(policy.allowedPatterns('bash').single, contains('(regex)'));
  });

  test('full match handles alternative lengths and rejects trailing newlines',
      () {
    final policy = PermissionPolicy(defaults: {
      'write': PermissionDecision.ask
    }, rules: [
      allow(r'write:foo|foobar'),
    ]);
    expect(policy.check('write', {'filePath': 'foobar'}),
        PermissionDecision.allow);
    expect(
        policy.check('write', {'filePath': 'foo\n'}), PermissionDecision.ask);
  });

  test(
      'regex paths, URLs and serialized invocations use their existing targets',
      () {
    final execInput = {
      'executable': 'git',
      'args': ['status'],
      'cwd': '/repo'
    };
    final policy = PermissionPolicy(defaults: {
      'read': PermissionDecision.ask
    }, rules: [
      allow(r'read:/repo/(src|test)/.*\.dart'),
      allow(r'fetch:https://example\.com/(docs|api)/[0-9]{1,3}'),
      allow(
          'exec:${RegExp.escape(PermissionPolicy.keyFor('exec', execInput))}'),
    ]);
    expect(policy.check('read', {'filePath': '/repo/src/sub/file.dart'}),
        PermissionDecision.allow);
    expect(policy.check('read', {'filePath': '/repo/private/file.dart'}),
        PermissionDecision.ask);
    expect(policy.check('fetch', {'url': 'https://example.com/api/123'}),
        PermissionDecision.allow);
    expect(policy.check('exec', execInput), PermissionDecision.allow);
    expect(policy.check('exec', {...execInput, 'cwd': '/other'}),
        PermissionDecision.ask);
  });

  test('saved rules retain regex type; old rules keep glob semantics', () {
    final policy = PermissionPolicy(rules: [
      allow(r'bash:git (status|diff)'),
      const PermissionRule(
          toolName: 'bash',
          pattern: 'echo (a|b)*',
          decision: PermissionDecision.allow),
    ]);
    final restored = PermissionPolicy.fromJson(policy.toJson());
    expect(restored.staticRules.first.isRegex, isTrue);
    expect(restored.staticRules.last.isRegex, isFalse);
    expect(restored.check('bash', {'command': 'git diff'}),
        PermissionDecision.allow);
    expect(restored.check('bash', {'command': 'echo (a|b) hello'}),
        PermissionDecision.allow);
    expect(
        restored.check('bash', {'command': 'echo a'}), PermissionDecision.ask);
  });

  test('malformed regex and unknown stored match types are rejected', () {
    for (final pattern in ['[', 'foo)|(?:.*']) {
      expect(() => allow('bash:$pattern'), throwsFormatException);
      expect(
          () => PermissionRule.fromJson({
                'toolName': 'bash',
                'pattern': pattern,
                'decision': 'allow',
                'match': 'regex',
              }),
          throwsFormatException);
    }
    expect(
        () => PermissionRule.fromJson({
              'toolName': 'bash',
              'pattern': '*',
              'decision': 'allow',
              'match': 'typo',
            }),
        throwsFormatException);
  });

  test('regex rules retain mode boundaries and classifier grant precedence',
      () {
    final deny = parsePermissionRule(
        r'bash:git (push|commit).*', PermissionDecision.deny,
        regex: true);
    final policy = PermissionPolicy(rules: [deny, allow('bash:.*')]);
    policy.remember('bash', 'git push', PermissionDecision.allow,
        source: GrantSource.classifier);
    expect(
        policy.check('bash', {'command': 'git push'}), PermissionDecision.deny);
    policy.mode = PermissionMode.readAll;
    expect(policy.check('bash', {'command': 'touch file'}),
        PermissionDecision.deny);
  });
}
