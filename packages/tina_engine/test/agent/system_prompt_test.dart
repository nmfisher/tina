import 'dart:io';

import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

void main() {
  group('resolveMainPrompt', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_sysprompt_');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('returns the identity + environment block when no AGENTS.md exists', () {
      final s = resolveMainPrompt(defaultPipeline, cwd: tmp.path);
      expect(s, contains('coding assistant'));
      expect(s, contains('<environment>'));
      expect(s, contains('cwd:'));
      expect(s, isNot(contains('<project-context>')));
    });

    test('injects AGENTS.md content found in cwd', () {
      File('${tmp.path}/AGENTS.md')
          .writeAsStringSync('# project rules\n- always run dart format\n');
      final s = resolveMainPrompt(defaultPipeline, cwd: tmp.path);
      expect(s, contains('<project-context>'));
      expect(s, contains('always run dart format'));
      expect(s, contains('AGENTS.md'));
    });

    test('concatenates outer and inner AGENTS.md, inner last', () {
      final inner = Directory('${tmp.path}/sub')..createSync();
      File('${tmp.path}/AGENTS.md').writeAsStringSync('OUTER RULE\n');
      File('${inner.path}/AGENTS.md').writeAsStringSync('INNER RULE\n');
      final s = resolveMainPrompt(defaultPipeline, cwd: inner.path);
      final outerIdx = s.indexOf('OUTER RULE');
      final innerIdx = s.indexOf('INNER RULE');
      expect(outerIdx, isNonNegative);
      expect(innerIdx, isNonNegative);
      expect(outerIdx, lessThan(innerIdx),
          reason: 'innermost AGENTS.md should win — render it last');
    });
  });

  group('resolveMainPrompt overrides', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_resolveprompt_');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('uses the [prompts.main] override when one is set', () {
      const identity = 'You are a totally bespoke agent. Squawk like a parrot.';
      final s = resolveMainPrompt(
        defaultPipeline,
        overrides: {'main': identity},
        cwd: tmp.path,
      );
      expect(s, contains(identity));
      expect(s, isNot(contains('coding assistant')));
      // The wrapper still applies on top of the override.
      expect(s, contains('<environment>'));
      expect(s, contains('cwd:'));
    });

    test('an empty override falls back to the main identity', () {
      final withEmpty = resolveMainPrompt(
        defaultPipeline,
        overrides: {'main': ''},
        cwd: tmp.path,
      );
      final withNone = resolveMainPrompt(defaultPipeline, cwd: tmp.path);
      expect(withEmpty, equals(withNone));
      expect(withEmpty, contains('coding assistant'));
    });

    test('the override only replaces identity; the AGENTS.md wrapper survives',
        () {
      File('${tmp.path}/AGENTS.md').writeAsStringSync('PROJECT RULE\n');
      const identity = 'Custom identity with no AGENTS mention.';
      final s = resolveMainPrompt(
        defaultPipeline,
        overrides: {'main': identity},
        cwd: tmp.path,
      );
      expect(s, contains('PROJECT RULE'));
      expect(s, contains('<project-context>'));
    });
  });

  group('resolveMainPrompt safe-mode', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_sysprompt_safe_');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('prepends the <safe-mode> block when safeMode is true', () {
      final s =
          resolveMainPrompt(defaultPipeline, cwd: tmp.path, safeMode: true);
      expect(s, contains('<safe-mode>'));
      expect(s, contains('READ-ONLY'));
      expect(s, contains('write, edit'));
      expect(s, contains('</safe-mode>'));
      // The preamble leads the identity.
      expect(s.indexOf('<safe-mode>'), lessThan(s.indexOf('coding assistant')));
    });

    test('omits the preamble when safeMode is false (default)', () {
      final s = resolveMainPrompt(defaultPipeline, cwd: tmp.path);
      expect(s, isNot(contains('<safe-mode>')));
    });

    test('preamble survives an override identity', () {
      final s = resolveMainPrompt(
        defaultPipeline,
        overrides: {'main': 'Custom identity.'},
        cwd: tmp.path,
        safeMode: true,
      );
      expect(s, contains('<safe-mode>'));
      expect(s, contains('Custom identity.'));
    });
  });

  group('resolveMainPrompt project-trust gating', () {
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
      final s = resolveMainPrompt(defaultPipeline,
          cwd: tmp.path, loadProjectContext: false);
      expect(s, isNot(contains('<project-context>')));
      expect(s, isNot(contains('UNTRUSTED PROJECT RULE')));
      // Identity + environment still present.
      expect(s, contains('coding assistant'));
      expect(s, contains('<environment>'));
    });

    test('loads AGENTS.md when loadProjectContext is true (default)', () {
      final s = resolveMainPrompt(defaultPipeline, cwd: tmp.path);
      expect(s, contains('<project-context>'));
      expect(s, contains('UNTRUSTED PROJECT RULE'));
    });
  });

  group('defaultPipeline main identity', () {
    test('carries a non-empty identity, sans wrapper', () {
      expect(defaultPipeline.mainIdentity, isNotEmpty);
      expect(defaultPipeline.mainIdentity, isNot(contains('<environment>')));
      expect(defaultPipeline.mainIdentity, isNot(contains('<project-context>')));
    });

    test('the identity carries its distinctive marker', () {
      expect(defaultPipeline.mainIdentity, contains('coding assistant'));
    });
  });

  group('resolveIdentityPrompt (node identity)', () {
    test('wraps a bare identity with the environment block', () {
      final s = resolveIdentityPrompt('NODE-IDENTITY');
      expect(s, contains('NODE-IDENTITY'));
      expect(s, contains('<environment>'));
    });
  });
}
