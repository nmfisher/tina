import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('resolveSystemPrompt', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_sysprompt_');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('returns the identity + environment block when no AGENTS.md exists', () {
      final s = resolveSystemPrompt(defaultPipeline.mainRole, cwd: tmp.path);
      expect(s, contains('coding assistant'));
      expect(s, contains('<environment>'));
      expect(s, contains('cwd:'));
      expect(s, isNot(contains('<project-context>')));
    });

    test('injects AGENTS.md content found in cwd', () {
      File('${tmp.path}/AGENTS.md')
          .writeAsStringSync('# project rules\n- always run dart format\n');
      final s = resolveSystemPrompt(defaultPipeline.mainRole, cwd: tmp.path);
      expect(s, contains('<project-context>'));
      expect(s, contains('always run dart format'));
      expect(s, contains('AGENTS.md'));
    });

    test('concatenates outer and inner AGENTS.md, inner last', () {
      final inner = Directory('${tmp.path}/sub')..createSync();
      File('${tmp.path}/AGENTS.md').writeAsStringSync('OUTER RULE\n');
      File('${inner.path}/AGENTS.md').writeAsStringSync('INNER RULE\n');
      final s =
          resolveSystemPrompt(defaultPipeline.mainRole, cwd: inner.path);
      final outerIdx = s.indexOf('OUTER RULE');
      final innerIdx = s.indexOf('INNER RULE');
      expect(outerIdx, isNonNegative);
      expect(innerIdx, isNonNegative);
      expect(outerIdx, lessThan(innerIdx),
          reason: 'innermost AGENTS.md should win — render it last');
    });
  });

  group('resolveSystemPrompt overrides', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_resolveprompt_');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('uses the override identity when one is set for the role', () {
      const identity = 'You are a totally bespoke agent. Squawk like a parrot.';
      final s = resolveSystemPrompt(
        defaultPipeline.mainRole,
        overrides: {'main': identity},
        cwd: tmp.path,
      );
      expect(s, contains(identity));
      expect(s, isNot(contains('coding assistant')));
      // The wrapper still applies on top of the override.
      expect(s, contains('<environment>'));
      expect(s, contains('cwd:'));
    });

    test('an empty override falls back to the role identity', () {
      final research = defaultPipeline.role('research')!;
      final withEmpty = resolveSystemPrompt(
        research,
        overrides: {'research': ''},
        cwd: tmp.path,
      );
      final withNone = resolveSystemPrompt(research, cwd: tmp.path);
      expect(withEmpty, equals(withNone));
      expect(withEmpty, contains('read, search, grep, and glob'));
    });

    test('a role absent from the override map uses its identity', () {
      final verifier = defaultPipeline.role('verifier')!;
      final s = resolveSystemPrompt(
        verifier,
        overrides: {'main': 'unrelated'},
        cwd: tmp.path,
      );
      expect(s, contains('code-review agent'));
    });

    test('the override only replaces identity; the AGENTS.md wrapper survives',
        () {
      File('${tmp.path}/AGENTS.md').writeAsStringSync('PROJECT RULE\n');
      const identity = 'Custom identity with no AGENTS mention.';
      final s = resolveSystemPrompt(
        defaultPipeline.mainRole,
        overrides: {'main': identity},
        cwd: tmp.path,
      );
      expect(s, contains('PROJECT RULE'));
      expect(s, contains('<project-context>'));
    });
  });

  group('resolveSystemPrompt safe-mode', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_sysprompt_safe_');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('prepends the <safe-mode> block when safeMode is true', () {
      final s = resolveSystemPrompt(defaultPipeline.mainRole,
          cwd: tmp.path, safeMode: true);
      expect(s, contains('<safe-mode>'));
      expect(s, contains('READ-ONLY'));
      expect(s, contains('write, edit'));
      expect(s, contains('</safe-mode>'));
      // The preamble leads the identity.
      expect(s.indexOf('<safe-mode>'), lessThan(s.indexOf('coding assistant')));
    });

    test('omits the preamble when safeMode is false (default)', () {
      final s =
          resolveSystemPrompt(defaultPipeline.mainRole, cwd: tmp.path);
      expect(s, isNot(contains('<safe-mode>')));
    });

    test('preamble survives an override identity', () {
      final s = resolveSystemPrompt(
        defaultPipeline.mainRole,
        overrides: {'main': 'Custom identity.'},
        cwd: tmp.path,
        safeMode: true,
      );
      expect(s, contains('<safe-mode>'));
      expect(s, contains('Custom identity.'));
    });
  });

  group('resolveSystemPrompt project-trust gating', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_sysprompt_trust_');
      File('${tmp.path}/AGENTS.md')
          .writeAsStringSync('UNTRUSTED PROJECT RULE\n');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('withholds AGENTS.md when loadProjectContext is false', () {
      final s = resolveSystemPrompt(defaultPipeline.mainRole,
          cwd: tmp.path, loadProjectContext: false);
      expect(s, isNot(contains('<project-context>')));
      expect(s, isNot(contains('UNTRUSTED PROJECT RULE')));
      // Identity + environment still present.
      expect(s, contains('coding assistant'));
      expect(s, contains('<environment>'));
    });

    test('loads AGENTS.md when loadProjectContext is true (default)', () {
      final s = resolveSystemPrompt(defaultPipeline.mainRole, cwd: tmp.path);
      expect(s, contains('<project-context>'));
      expect(s, contains('UNTRUSTED PROJECT RULE'));
    });
  });

  group('defaultPipeline identities', () {
    test('every role carries a non-empty identity, sans wrapper', () {
      for (final role in [defaultPipeline.mainRole, ...defaultPipeline.roles]) {
        expect(role.promptIdentity, isNotEmpty, reason: role.name);
        expect(role.promptIdentity, isNot(contains('<environment>')));
        expect(role.promptIdentity, isNot(contains('<project-context>')));
      }
    });

    test('each role identity carries its distinctive marker', () {
      final markers = {
        'main': 'coding assistant',
        'research': 'find files that are relevant',
        'implementer': 'implementation agent',
        'verifier': 'code-review agent',
        'tester': 'test-writing agent',
        'orchestrator': 'orchestrate a fleet',
        'scout': 'scout agent',
      };
      for (final entry in markers.entries) {
        final role = entry.key == 'main'
            ? defaultPipeline.mainRole
            : defaultPipeline.role(entry.key)!;
        expect(role.promptIdentity, contains(entry.value), reason: entry.key);
      }
    });
  });
}
