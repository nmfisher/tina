import 'dart:io';

import 'package:attractor/attractor.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

import '../lib/pipeline/default_workflow.dart';

void main() {
  group('resolveDefaultWorkflowName', () {
    late Directory tmp;
    late Directory workflows;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_defwf_');
      workflows = Directory(p.join(tmp.path, 'workflows'));
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    void write(String name, String source) =>
        File(p.join(workflows.path, '$name.dot')).writeAsStringSync(source);

    test('null when the workflows dir is missing', () {
      expect(
          resolveDefaultWorkflowName(
              configured: null, workflowsDir: workflows),
          isNull);
    });

    test('default.dot present -> "default"', () {
      workflows.createSync(recursive: true);
      write('default', 'digraph d {}');
      expect(
          resolveDefaultWorkflowName(
              configured: null, workflowsDir: workflows),
          'default');
      expect(
          resolveDefaultWorkflowName(
              configured: '', workflowsDir: workflows),
          'default');
    });

    test('configured "none" disables even when default.dot exists', () {
      workflows.createSync(recursive: true);
      write('default', 'digraph d {}');
      expect(
          resolveDefaultWorkflowName(
              configured: 'none', workflowsDir: workflows),
          isNull);
    });

    test('configured name requires that file to exist', () {
      workflows.createSync(recursive: true);
      write('foo', 'digraph f {}');
      expect(
          resolveDefaultWorkflowName(
              configured: 'foo', workflowsDir: workflows),
          'foo');
      expect(
          resolveDefaultWorkflowName(
              configured: 'bar', workflowsDir: workflows),
          isNull);
    });
  });

  group('formatChatHistory', () {
    test('renders user/assistant text lines, oldest first', () {
      final h = [
        const Message(role: Role.user, content: [TextBlock('hi')]),
        const Message(role: Role.assistant, content: [TextBlock('hello')]),
      ];
      expect(formatChatHistory(h), 'user: hi\n\nassistant: hello');
    });

    test('skips tool blocks and empty text', () {
      final h = [
        const Message(role: Role.assistant, content: [
          TextBlock(''),
          ToolUseBlock(id: 't1', name: 'read', input: {'path': 'x'}),
          TextBlock('done'),
        ]),
      ];
      expect(formatChatHistory(h), 'assistant: done');
    });

    test('keeps the newest messages once the cap is hit', () {
      final h = [
        Message(role: Role.user, content: [TextBlock('oldest ' * 1000)]),
        const Message(role: Role.user, content: [TextBlock('newest')]),
      ];
      expect(formatChatHistory(h, maxChars: 100), 'user: newest');
    });

    test('newest message always included, head-trimmed when oversized', () {
      final h = [
        Message(role: Role.user, content: [TextBlock('x' * 5000)]),
      ];
      final out = formatChatHistory(h, maxChars: 100);
      expect(out.startsWith('user: '), isTrue);
      expect(out.length, 101); // 100 chars + '…' (label included in the block)
      expect(out.endsWith('…'), isTrue);
    });

    test('empty history -> empty string', () {
      expect(formatChatHistory(const []), '');
    });
  });

  group('seedDefaultWorkflow', () {
    late Directory tmp;
    late Directory workflows;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_seed_');
      workflows = Directory(p.join(tmp.path, 'workflows'));
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    test('creates the dir + default.dot; second call is a no-op', () {
      expect(seedDefaultWorkflow(workflows), isTrue);
      expect(
          File(p.join(workflows.path, 'default.dot')).existsSync(), isTrue);
      expect(seedDefaultWorkflow(workflows), isFalse);
    });

    test('seed parses and validates cleanly with the resolvable roles', () {
      seedDefaultWorkflow(workflows);
      final source =
          File(p.join(workflows.path, 'default.dot')).readAsStringSync();
      final graph = parseDot(source);
      // The runner validates against the pipeline's resolvable role names
      // (main + sub-roles), so the seeded `main` node must be "known" — no
      // role_unknown warning.
      final diags = validate(graph,
          knownRoles: defaultPipeline.resolvableRoleNames);
      expect(diags.where((d) => d.severity == Severity.error), isEmpty);
      expect(diags.where((d) => d.severity == Severity.warning), isEmpty);
      // structure: start -> main -> done (one chat agent that delegates).
      expect(graph.nodes.keys, containsAll(['start', 'main', 'done']));
      expect(graph.findStartNode()!.id, 'start');
      expect(graph.isTerminal(graph.node('done')!), isTrue);
    });

    test('seed is one main node that delegates to research (no orchestrator)',
        () {
      seedDefaultWorkflow(workflows);
      final source =
          File(p.join(workflows.path, 'default.dot')).readAsStringSync();
      // The default chat experience is one main agent (no file tools,
      // canDelegate) that delegates repository exploration to research.
      expect(source, contains('role="main"'));
      expect(source, contains('research'));
      // The repo-overview orchestrator/scout flow no longer runs as the default.
      expect(source, isNot(contains('orchestrator')));
      expect(source, isNot(contains('scout')));
    });
  });

  group('ensureDefaultWorkflowUsable', () {
    late Directory tmp;
    late Directory workflows;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('tina_usbl_');
      workflows =
          Directory(p.join(tmp.path, 'workflows'))..createSync(recursive: true);
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    Future<void> write(String name, String source) =>
        File(p.join(workflows.path, '$name.dot')).writeAsString(source);

    test('valid file passes', () async {
      await write('ok', kDefaultWorkflowDotSource);
      await ensureDefaultWorkflowUsable(workflows, 'ok');
    });

    test('missing file throws', () {
      expect(() => ensureDefaultWorkflowUsable(workflows, 'nope'),
          throwsA(isA<DefaultWorkflowUnusable>()));
    });

    test('unparseable source throws', () async {
      await write('bad', 'digraph {');
      await expectLater(ensureDefaultWorkflowUsable(workflows, 'bad'),
          throwsA(isA<DefaultWorkflowUnusable>()));
    });

    test('validation error (no terminal node) throws', () async {
      await write('noexit', 'digraph e { start [shape=Mdiamond] }');
      await expectLater(ensureDefaultWorkflowUsable(workflows, 'noexit'),
          throwsA(isA<DefaultWorkflowUnusable>()));
    });
  });
}
