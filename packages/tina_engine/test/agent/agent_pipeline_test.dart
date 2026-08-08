import 'package:tina_engine/tina_engine.dart';
import 'package:test/test.dart';

import '../helpers/fake_tool.dart';

void main() {
  group('AgentPipeline', () {
    test('carries the entry identity and a mutable project-context flag', () {
      final p = AgentPipeline(mainIdentity: 'the main agent');
      expect(p.mainIdentity, 'the main agent');
      expect(p.loadProjectContext, isTrue); // default
      p.loadProjectContext = false; // mutable (a late startup decision)
      expect(p.loadProjectContext, isFalse);
    });

    test('defaultPipeline carries the shipped main identity', () {
      expect(defaultPipeline.mainIdentity, isNotEmpty);
      expect(defaultPipeline.mainIdentity, contains('coding assistant'));
    });
  });

  group('ToolProfile tool sets', () {
    test('read-only has the read/explore tools + write_summary, no mutations',
        () {
      final names = toolSetFor(ToolProfile.readOnly).map((t) => t.schema.name).toSet();
      expect(names, containsAll(['read', 'search', 'grep', 'glob', 'write_summary']));
      expect(names, isNot(containsAny(['write', 'edit', 'bash'])));
    });

    test('full is a superset of read-only plus the mutating tools', () {
      final ro = toolSetFor(ToolProfile.readOnly).map((t) => t.schema.name).toSet();
      final full = toolSetFor(ToolProfile.full).map((t) => t.schema.name).toSet();
      expect(full, containsAll(['read', 'write', 'edit', 'bash', 'search', 'grep',
          'glob', 'write_summary']));
      // read-only's tools are all in full.
      expect(full.containsAll(ro), isTrue);
    });

    test('parseToolProfile maps the strings; unknown/empty → read-only', () {
      expect(parseToolProfile('read-only'), ToolProfile.readOnly);
      expect(parseToolProfile('full'), ToolProfile.full);
      expect(parseToolProfile(null), ToolProfile.readOnly);
      expect(parseToolProfile(''), ToolProfile.readOnly);
      expect(parseToolProfile('bogus'), ToolProfile.readOnly);
    });

    test('toolsFromPolicy reconstructs the singletons an allow-list names', () {
      final policy = PermissionPolicy(defaults: {
        'read': PermissionDecision.allow,
        'bash': PermissionDecision.allow,
        'glob': PermissionDecision.allow,
        'write': PermissionDecision.deny,
        'made-up': PermissionDecision.allow, // not a real tool → dropped
      });
      final names = toolsFromPolicy(policy).map((t) => t.schema.name).toSet();
      expect(names, containsAll(['read', 'bash', 'glob']));
      // Denied / unknown names are not reconstructed.
      expect(names, isNot(contains('write')));
      expect(names, isNot(contains('made-up')));
    });
  });

  group('stripForSafeMode (--safe-mode)', () {
    test('drops write/edit/bash, keeps the read-only tools', () {
      final tools = [
        FakeTool.noOp('read'),
        FakeTool.noOp('write'),
        FakeTool.noOp('edit'),
        FakeTool.noOp('bash'),
        FakeTool.noOp('grep'),
        FakeTool.noOp('glob'),
        FakeTool.noOp('search'),
      ];
      final stripped =
          stripForSafeMode(tools).map((t) => t.schema.name).toSet();
      expect(stripped, containsAll(['read', 'grep', 'glob', 'search']));
      expect(stripped, isNot(containsAll(['write', 'edit', 'bash'])));
      expect(stripped.intersection(kSafeModeDisabledTools), isEmpty);
    });

    test('leaves a read-only-only set unchanged', () {
      final tools = [FakeTool.noOp('read'), FakeTool.noOp('grep')];
      final stripped =
          stripForSafeMode(tools).map((t) => t.schema.name).toSet();
      expect(stripped, ['read', 'grep']);
    });

    test('safe-mode drops the mutating tools from the full profile', () {
      final stripped = stripForSafeMode(toolSetFor(ToolProfile.full))
          .map((t) => t.schema.name)
          .toSet();
      expect(stripped, contains('read'));
      expect(stripped.intersection(kSafeModeDisabledTools), isEmpty);
    });
  });
}

/// Matches when the set contains none of [names].
Matcher containsAny(Iterable<String> names) =>
    predicate<Set<String>>((s) => names.any(s.contains), 'contains any of $names');
