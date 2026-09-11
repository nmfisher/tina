import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

/// The `--yolo` posture: [PermissionPolicy.allowAllByDefault] widens EVERY
/// default to allow — the table's own `ask` entries and the unmapped-tool
/// fallback alike — without replacing the table. Static/session rules and the
/// mode's hard boundary still apply.
void main() {
  group('allowAllByDefault (--yolo) widening', () {
    test('tools allowed by the built-in table stay allowed', () {
      final p = PermissionPolicy(allowAllByDefault: true);
      for (final tool in const [
        'read',
        'search',
        'grep',
        'glob',
        'ls',
        'stat',
        'which',
        'git',
      ]) {
        expect(p.check(tool, const {}), PermissionDecision.allow,
            reason: '$tool must stay allow under --yolo');
      }
    });

    test('tools gated by the built-in table are widened to allow', () {
      final p = PermissionPolicy(allowAllByDefault: true);
      expect(p.check('write', const {'filePath': '/x'}),
          PermissionDecision.allow);
      expect(p.check('edit', const {'filePath': '/x'}),
          PermissionDecision.allow);
      expect(p.check('bash', const {'command': 'git status'}),
          PermissionDecision.allow);
    });

    test('network reads are widened to allow', () {
      final p = PermissionPolicy(allowAllByDefault: true);
      expect(p.check('fetch', const {'url': 'https://example.com'}),
          PermissionDecision.allow);
      expect(p.check('web_search', const {'query': 'x'}),
          PermissionDecision.allow);
    });

    test('an unknown tool name is widened to allow, not ask', () {
      final p = PermissionPolicy(allowAllByDefault: true);
      expect(p.check('totally_unknown_tool', const {}),
          PermissionDecision.allow,
          reason:
              'the flag widens the fallback, so a tool added later cannot '
              'silently regress to ask');
    });

    test('an explicit deny rule still denies the exact call', () {
      final p = PermissionPolicy(
        allowAllByDefault: true,
        rules: const [
          PermissionRule(
            toolName: 'bash',
            pattern: 'rm *',
            decision: PermissionDecision.deny,
          ),
        ],
      );
      expect(p.check('bash', const {'command': 'rm -rf /tmp/x'}),
          PermissionDecision.deny);
      // Sibling commands keep the widened default.
      expect(p.check('bash', const {'command': 'git status'}),
          PermissionDecision.allow);
    });

    test('a tool-wide deny rule denies every call of that tool', () {
      final p = PermissionPolicy(
        allowAllByDefault: true,
        rules: const [
          PermissionRule(
            toolName: 'glob',
            pattern: '*',
            decision: PermissionDecision.deny,
          ),
        ],
      );
      expect(p.check('glob', const {'pattern': '**/*.dart'}),
          PermissionDecision.deny);
    });

    test('a remembered session deny still denies', () {
      final p = PermissionPolicy(allowAllByDefault: true);
      p.remember('bash', 'curl *', PermissionDecision.deny);
      expect(p.check('bash', const {'command': 'curl example.com'}),
          PermissionDecision.deny);
    });

    test('read-all mode still blocks mutating tools under the flag', () {
      final p = PermissionPolicy(
        allowAllByDefault: true,
        mode: PermissionMode.readAll,
      );
      expect(
          p.check('bash', const {'command': 'git status'}),
          PermissionDecision.deny,
          reason: 'executionBlock is a hard boundary: it never opens a '
              'prompt and yolo cannot lift it');
      expect(p.check('write', const {'filePath': '/x'}),
          PermissionDecision.deny);
      expect(p.check('fetch', const {'url': 'https://example.com'}),
          PermissionDecision.allow);
    });

    test('allowEdits behaves as without the flag', () {
      final p = PermissionPolicy(
        allowAllByDefault: true,
        mode: PermissionMode.allowEdits,
      );
      expect(p.check('write', const {'filePath': '/x'}),
          PermissionDecision.allow);
      expect(p.check('edit', const {'filePath': '/x'}),
          PermissionDecision.allow);
      expect(
          p.check('bash', const {'command': 'ls'}),
          PermissionDecision.allow,
          reason:
              'allowEdits leaves bash at its default, which yolo widened — '
              'yolo is the wider grant, allowEdits only narrows nothing');
    });

    test('allowEdits alone (no flag) still asks for bash — unchanged', () {
      final p = PermissionPolicy(mode: PermissionMode.allowEdits);
      expect(p.check('bash', const {'command': 'ls'}), PermissionDecision.ask);
    });

    test('a derived policy copy carries the posture', () {
      final parent = PermissionPolicy(allowAllByDefault: true);
      final child = PermissionPolicy(
        defaults: parent.defaults,
        rules: parent.staticRules,
        modeSource: parent,
        allowAllByDefault: parent.allowAllByDefault,
      );
      expect(child.check('fetch', const {}), PermissionDecision.allow);
      expect(child.check('bash', const {'command': 'ls'}),
          PermissionDecision.allow);
      expect(child.check('made_up_tool', const {}), PermissionDecision.allow);
    });

    test('the posture survives persistence round-trip', () {
      final p = PermissionPolicy(
        allowAllByDefault: true,
        rules: const [
          PermissionRule(
            toolName: 'bash',
            pattern: 'rm *',
            decision: PermissionDecision.deny,
          ),
        ],
      );
      final restored = PermissionPolicy.fromJson(p.toJson());
      expect(restored.allowAllByDefault, isTrue);
      expect(restored.check('fetch', const {}), PermissionDecision.allow);
      expect(restored.check('no_such_tool', const {}),
          PermissionDecision.allow);
      expect(restored.check('bash', const {'command': 'rm -rf /'}),
          PermissionDecision.deny);
    });

    test('a policy without the flag parses legacy JSON as before', () {
      final legacy = PermissionPolicy.fromJson({
        'defaults': {'read': 'allow'},
        'staticRules': <Map<String, dynamic>>[],
      });
      expect(legacy.allowAllByDefault, isFalse);
      expect(legacy.check('fetch', const {}), PermissionDecision.ask);
      expect(legacy.check('made_up', const {}), PermissionDecision.ask);
    });

    test('the defaults table itself is not rewritten by the flag', () {
      final p = PermissionPolicy(allowAllByDefault: true);
      // /permissions renders this table; the widening must live in the flag,
      // not in a mutated map, so the display stays truthful.
      expect(p.defaults['write'], PermissionDecision.ask);
      expect(p.defaults['bash'], PermissionDecision.ask);
      expect(p.defaults.containsKey('launch_workflow'), isFalse);
    });
  });
}
