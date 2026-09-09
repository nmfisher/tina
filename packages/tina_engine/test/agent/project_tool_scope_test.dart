import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

void main() {
  late Directory temp;
  late Directory first;
  late Directory second;
  late Map<String, String> env;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('tina-tool-scopes-');
    first = Directory('${temp.path}/first')..createSync();
    second = Directory('${temp.path}/second')..createSync();
    env = {'HOME': '${temp.path}/home'};
  });

  tearDown(() => temp.deleteSync(recursive: true));

  ProjectToolScope scope(Directory root, {bool sandboxEnabled = false}) =>
      ProjectToolScope(
        projectRoot: root.path,
        env: env,
        sandboxEnabled: sandboxEnabled,
      );

  test(
      'sandbox session grants belong to the project scope and all its borrowers',
      () {
    env['TINA_SANDBOX_ALLOW'] = second.path;
    final a = scope(first, sandboxEnabled: true);
    final initial = (a.buildTools()['bash'] as BashTool).processRunner
        as SandboxedProcessRunner;
    expect(initial.accessPolicy.writablePaths,
        contains(second.resolveSymbolicLinksSync()));
    final cache = Directory('${temp.path}/cache')..createSync();
    initial.accessPolicy.grantForSession(
        SandboxAccessRequest([cache.resolveSymbolicLinksSync()], 'cache'));
    final borrowed = (a.buildTools()['bash'] as BashTool).processRunner
        as SandboxedProcessRunner;
    expect(borrowed.accessPolicy, same(initial.accessPolicy));
    final b = scope(second, sandboxEnabled: true);
    final independent = (b.buildTools()['bash'] as BashTool).processRunner
        as SandboxedProcessRunner;
    expect(independent.accessPolicy.writablePaths,
        isNot(contains(cache.resolveSymbolicLinksSync())));
  });

  test('a second project cannot reconfigure existing file tools', () async {
    final source = File('${first.path}/source.txt')..writeAsStringSync('first');
    final other = File('${second.path}/source.txt')
      ..writeAsStringSync('second');
    final a = scope(first);
    final firstTools = a.buildTools();
    expect(
        (await firstTools['read']!.execute({'filePath': source.path})).content,
        contains('first'));

    final b = scope(second);
    final secondTools = b.buildTools();
    final results = await Future.wait([
      firstTools['write']!.execute({'filePath': source.path, 'content': 'A'}),
      secondTools['write']!.execute({'filePath': other.path, 'content': 'B'}),
    ]);
    expect(results.every((result) => !result.isError), isTrue);
    expect(source.readAsStringSync(), 'A');
    expect(other.readAsStringSync(), 'B');

    expect(
        (await firstTools['read']!.execute({'filePath': source.path})).content,
        contains('A'));
    expect(
        (await firstTools['read']!.execute({'filePath': other.path})).isError,
        isTrue);
    expect(
        (await secondTools['read']!.execute({'filePath': source.path})).isError,
        isTrue);
  });

  test('relative file paths and default listings use the captured root',
      () async {
    File('${first.path}/source.txt').writeAsStringSync('first project');
    File('${second.path}/source.txt').writeAsStringSync('second project');
    final a = scope(first).buildTools();
    final b = scope(second).buildTools();
    for (final entry in [(a, first, 'first'), (b, second, 'second')]) {
      final (tools, root, label) = entry;
      expect((await tools['read']!.execute({'filePath': 'source.txt'})).content,
          contains(label));
      expect(
          (await tools['write']!
                  .execute({'filePath': 'new.txt', 'content': label}))
              .isError,
          isFalse);
      expect(File('${root.path}/new.txt').readAsStringSync(), label);
      expect(
          (await tools['edit']!.execute({
            'filePath': 'new.txt',
            'oldString': label,
            'newString': 'edited'
          }))
              .isError,
          isFalse);
      expect(File('${root.path}/new.txt').readAsStringSync(), 'edited');
      expect((await tools['ls']!.execute({})).content, contains('source.txt'));
      expect((await tools['glob']!.execute({'pattern': '*.txt'})).content,
          contains('source.txt'));
      expect((await tools['stat']!.execute({'path': 'source.txt'})).isError,
          isFalse);
      expect((await tools['grep']!.execute({'pattern': label})).content,
          contains('source.txt'));
      expect((await tools['bash']!.execute({'command': 'pwd'})).content,
          contains(root.resolveSymbolicLinksSync()));
    }
  });

  test('profiles and restored policies borrow the project write lock', () {
    final a = scope(first);
    final main = a.buildTools();
    final delegated = ToolRegistry(a.toolSetFor(ToolProfile.full));
    final restored = ToolRegistry(a.toolsFromPolicy(PermissionPolicy(defaults: {
      'write': PermissionDecision.allow,
      'edit': PermissionDecision.allow,
    })));

    for (final tools in [main, delegated, restored]) {
      expect((tools['write']! as WriteTool).mutationLock, same(a.mutationLock));
      expect((tools['edit']! as EditTool).mutationLock, same(a.mutationLock));
    }
    final b = scope(second);
    expect(b.mutationLock, isNot(same(a.mutationLock)));
    expect(b.buildTools()['write'], isNot(same(main['write'])));
  });

  test('search, git and summary destinations belong to their project', () {
    final a = scope(first);
    final tools = ToolRegistry(a.toolSetFor(ToolProfile.full));
    scope(second);

    expect((tools['search']! as SearchTool).repoRoot, a.projectRoot);
    expect((tools['git']! as GitTool).workingDirectory, a.projectRoot);
    final summary = tools['write_summary']! as WriteSummaryTool;
    expect(summary.projectRoot, a.projectRoot);
    expect(summary.sidecarRoot!.path, '${a.projectRoot}/.tina/summaries');
  });

  test('sandboxed and pass-through shells can coexist', () {
    final a = scope(first, sandboxEnabled: true);
    final bashA = a.buildTools()['bash']! as BashTool;
    final b = scope(second);
    final bashB = b.buildTools()['bash']! as BashTool;

    expect(bashA.processRunner, isA<SandboxedProcessRunner>());
    expect(bashB.processRunner, isA<IoProcessRunner>());
    expect(bashA.projectRoot, a.projectRoot);
    expect(bashB.projectRoot, b.projectRoot);
  });

  test('environment and optional search registration are scope snapshots', () {
    env['BRAVE_API_KEY'] = 'test-brave-key';
    final a = scope(first);
    env.remove('BRAVE_API_KEY');
    final b = scope(second);

    expect(a.buildTools()['web_search'], isA<WebSearchTool>());
    expect(b.buildTools()['web_search'], isNull);
    expect((a.buildTools()['which']! as WhichTool).environment,
        containsPair('BRAVE_API_KEY', 'test-brave-key'));
    expect(() => a.environment['HOME'] = 'different', throwsUnsupportedError);
  });

  test('safe-mode filtering remains effective for scoped profiles', () {
    final a = scope(first);
    expect(a.buildTools(safeMode: true).schemas.map((s) => s.name),
        isNot(contains('write')));
    for (final profile in ToolProfile.values) {
      final names = stripForSafeMode(a.toolSetFor(profile))
          .map((tool) => tool.schema.name)
          .toSet();
      expect(names.intersection(kSafeModeDisabledTools), isEmpty);
      expect(names, contains('read'));
    }
  });
}
