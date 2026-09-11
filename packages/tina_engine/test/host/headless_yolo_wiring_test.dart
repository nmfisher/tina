import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

/// End-to-end guard for the `--yolo` regression: a headless run with
/// `--yolo` refused `glob`, `ls`, `grep`, and `git` with
/// "refused (use --allow … or --yolo)" — the flag the operator already
/// passed. The posture must widen every default so those tools allow before
/// the asker is ever reached.
void main() {
  // The tools reported refused in real `tina --yolo` runs, plus the network
  // reads the built-in table gates and a name that does not exist yet.
  const reported = [
    'glob',
    'grep',
    'search',
    'ls',
    'stat',
    'which',
    'git',
    'fetch',
    'web_search',
  ];

  (PermissionPolicy, HeadlessHost) wired({bool yolo = false}) {
    final policy = PermissionPolicy(
      mode: PermissionMode.ask,
      allowAllByDefault: yolo,
    );
    final host = HeadlessHost(
      write: (_) {},
      writeErr: (_) {},
      permissionHints: !yolo,
    );
    return (policy, host);
  }

  test('every reported tool resolves allow before the asker under --yolo',
      () async {
    final (policy, host) = wired(yolo: true);
    final asker = host.askPermission;
    for (final tool in reported) {
      final decision = policy.check(tool, const {});
      expect(decision, PermissionDecision.allow,
          reason: '$tool must not ask (auto-deny) under --yolo');
    }
    // The unknown-tool fallback widens too.
    expect(policy.check('tool_from_a_future_release', const {}),
        PermissionDecision.allow);
    // The asker would refuse with a hint; with yolo in effect it must not.
    final response = await asker(
      const PermissionPrompt('bash', {'command': 'rm -rf /'}),
    );
    expect(response.decision, PermissionDecision.deny);
  });

  test('without --yolo the same wiring still asks for gated tools', () async {
    final (policy, host) = wired();
    expect(policy.check('fetch', const {'url': 'https://example.com'}),
        PermissionDecision.ask);
    final response = await host.askPermission(
      const PermissionPrompt('fetch', {'url': 'https://example.com'}),
    );
    expect(response.decision, PermissionDecision.deny,
        reason: 'headless asks auto-deny — the documented posture');
  });

  test('an allow default promoted by yolo keeps deny rules effective',
      () async {
    final (policy, _) = wired(yolo: true);
    final gated = PermissionPolicy(
      mode: policy.mode,
      allowAllByDefault: true,
      rules: const [
        PermissionRule(
          toolName: 'bash',
          pattern: 'rm *',
          decision: PermissionDecision.deny,
        ),
        PermissionRule(
          toolName: 'write',
          pattern: '/etc/**',
          decision: PermissionDecision.deny,
        ),
      ],
    );
    expect(gated.check('bash', const {'command': 'rm -rf /'}),
        PermissionDecision.deny);
    expect(gated.check('write', const {'filePath': '/etc/passwd'}),
        PermissionDecision.deny);
    expect(gated.check('write', const {'filePath': '/home/me/notes.txt'}),
        PermissionDecision.allow);
  });
}
