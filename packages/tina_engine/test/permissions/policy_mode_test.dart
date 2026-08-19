import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('PermissionPolicy modes', () {
    test('ask keeps the built-in defaults', () {
      final p = PermissionPolicy(mode: PermissionMode.ask);
      expect(p.check('read', const {}), PermissionDecision.allow);
      expect(p.check('write', const {'filePath': '/x'}), PermissionDecision.ask);
      expect(p.check('bash', const {'command': 'ls'}), PermissionDecision.ask);
      expect(p.check('fetch', const {}), PermissionDecision.ask);
    });

    test('readAll widens reads (including network) but not writes', () {
      final p = PermissionPolicy(mode: PermissionMode.readAll);
      expect(p.check('fetch', const {}), PermissionDecision.allow);
      expect(p.check('web_search', const {}), PermissionDecision.allow);
      expect(p.check('write', const {'filePath': '/x'}), PermissionDecision.ask);
      expect(p.check('bash', const {'command': 'ls'}), PermissionDecision.ask);
    });

    test('allowEdits widens write/edit but bash still asks', () {
      final p = PermissionPolicy(mode: PermissionMode.allowEdits);
      expect(p.check('write', const {'filePath': '/x'}), PermissionDecision.allow);
      expect(p.check('edit', const {'filePath': '/x'}), PermissionDecision.allow);
      expect(p.check('bash', const {'command': 'ls'}), PermissionDecision.ask);
    });

    test('auto gates identically to ask (the asker differs, not the map)', () {
      final p = PermissionPolicy(mode: PermissionMode.auto);
      expect(p.check('write', const {'filePath': '/x'}), PermissionDecision.ask);
      expect(p.check('read', const {}), PermissionDecision.allow);
    });

    test('static and session rules still win over the mode', () {
      final p = PermissionPolicy(
        mode: PermissionMode.allowEdits,
        rules: const [
          PermissionRule(
              toolName: 'write',
              pattern: '/etc/**',
              decision: PermissionDecision.deny),
        ],
      );
      expect(
          p.check('write', const {'filePath': '/etc/passwd'}),
          PermissionDecision.deny,
          reason: 'an explicit --deny must hold in every mode');
      p.remember('write', '/tmp/x', PermissionDecision.deny);
      expect(p.check('write', const {'filePath': '/tmp/x'}),
          PermissionDecision.deny);
    });

    test('mode is mutable — a later switch changes check()', () {
      final p = PermissionPolicy();
      expect(p.check('edit', const {'filePath': '/x'}), PermissionDecision.ask);
      p.mode = PermissionMode.allowEdits;
      expect(p.check('edit', const {'filePath': '/x'}), PermissionDecision.allow);
    });

    test('mode round-trips through toJson/fromJson; absent -> ask', () {
      final p = PermissionPolicy(mode: PermissionMode.auto);
      final restored = PermissionPolicy.fromJson(p.toJson());
      expect(restored.mode, PermissionMode.auto);
      // A serialized policy with no mode key (pre-modes session) reads as ask.
      final legacy = PermissionPolicy.fromJson({
        ...p.toJson()..remove('mode'),
      });
      expect(legacy.mode, PermissionMode.ask);
    });
  });
}
