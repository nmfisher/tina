import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_settings/tina_settings.dart';
import 'package:tina_tools/tina_tools.dart';
import 'package:tina_approvals/tina_approvals.dart';

final class Recorder implements ProcessRunner {
  final calls = <ProcessRequest>[];
  @override
  Future<RunOutcome> run(ProcessRequest request,
      {ProcessControl? control}) async {
    calls.add(request);
    return const CommandCompleted(
        exitCode: 0, stdout: 'reader output', stderr: '');
  }
}

ProcessRequest request(String command, List<String> args, Directory cwd) => (
      command: command,
      arguments: args,
      workingDirectory: cwd.path,
      environment: null,
      stdin: null,
      timeout: null,
    );

void main() {
  late Directory root, workspace, external, other;
  late File source;
  setUp(() {
    root = Directory.systemTemp.createTempSync('tina-read-dirs-');
    workspace = Directory('${root.path}/workspace')..createSync();
    external = Directory('${root.path}/external')..createSync();
    other = Directory('${root.path}/external-other')..createSync();
    source = File('${external.path}/source.txt')..writeAsStringSync('needle\n');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('saved read directories remove grep approval in every mode', () async {
    for (final mode in PermissionMode.values) {
      final directories = ReadOnlyDirectories();
      final inner = Recorder();
      var approvals = 0;
      final gate = SandboxedProcessRunner(
          inner: inner,
          mode: mode,
          readDirectories: directories,
          workspaceRoot: workspace.path,
          executableSearchPath: '/usr/bin:/bin',
          commandApprover: (_, __) async {
            approvals++;
            return Approval.no;
          });
      final call = request('grep',
          ['-rn', 'needle', '--include=*.txt', external.path], workspace);
      if (mode != PermissionMode.readOnly) {
        expect(await gate.run(call), isA<CommandRefused>());
        expect(approvals, 1);
      }
      directories.replace([external.path]);
      final before = approvals;
      expect(await gate.run(call), isA<CommandCompleted>());
      expect(approvals, before);
      expect(inner.calls.last.command, startsWith('/'));
      expect(gate.grants.isEmpty, isTrue);
      for (final program in ['cat', 'head', 'tail']) {
        expect(await gate.run(request(program, [source.path], workspace)),
            isA<CommandCompleted>());
      }
      directories.replace([]);
      if (mode != PermissionMode.readOnly) {
        expect(await gate.run(call), isA<CommandRefused>());
      }
    }
  }, skip: Platform.isWindows);

  test('directory grants check all operands and pattern files canonically',
      () async {
    final directories = ReadOnlyDirectories()..replace([external.path]);
    final outside = File('${other.path}/file')..writeAsStringSync('needle');
    final link = Link('${external.path}/escaped')..createSync(outside.path);
    final gate = SandboxedProcessRunner(
        inner: Recorder(),
        readDirectories: directories,
        workspaceRoot: workspace.path,
        executableSearchPath: '/usr/bin:/bin');
    for (final args in [
      ['needle', source.path, outside.path],
      ['needle', link.path],
      ['-f', outside.path, source.path],
      ['--exclude-from=${outside.path}', 'needle', source.path],
      ['--unsupported-option', 'needle', source.path],
    ]) {
      expect(await gate.run(request('grep', args, workspace)),
          isA<CommandRefused>(),
          reason: '$args');
    }
    for (final args in [
      ['--', 'needle', source.path],
      ['-e', 'needle', source.path],
      ['-f${source.path}', source.path],
      ['--file=${source.path}', source.path],
      ['-A2', 'needle', source.path],
    ]) {
      expect(await gate.run(request('grep', args, workspace)),
          isA<CommandCompleted>(),
          reason: '$args');
    }
    expect(
        await gate.run(request(
            '/bin/sh', ['-c', 'cat ${source.path} > written'], workspace)),
        isA<CommandRefused>());
    expect(
        await gate.run(request('cat', [source.path], workspace),
            control: const ProcessControl(
                networkRequested: true, networkReason: 'test')),
        isA<CommandRefused>());
  }, skip: Platform.isWindows);

  test('extra directories are mounted read-only and update the sandbox report',
      () async {
    final directories = ReadOnlyDirectories()..replace([external.path]);
    final spawn = Recorder();
    final plan = SandboxPlan(
        workspaceRoot: workspace.path, readDirectories: directories);
    final runner = OsSandboxRunner(
        inner: spawn,
        plan: plan,
        backend: SandboxBackend.bwrap,
        hostLayout: () => SandboxHostLayout(
            readOnlyDirectories: ['/bin'], temporaryDirectories: []));
    await runner.run(request('/bin/cat', [source.path], workspace));
    final argv = spawn.calls.single.arguments;
    final dir = external.resolveSymbolicLinksSync();
    final index = argv.indexOf(dir);
    expect(argv.sublist(index - 1, index + 2), ['--ro-bind', dir, dir]);
    expect(plan.writableLayout(), isNot(contains(dir)));
    expect(runner.describeEnvironment(), contains(dir));
    directories.replace([]);
    expect(runner.describeEnvironment(), isNot(contains(dir)));
  });

  test('literal shell readers reuse read access while scripts still ask',
      () async {
    final directories = ReadOnlyDirectories()..replace([external.path]);
    final spawn = Recorder();
    final gate = SandboxedProcessRunner(
        inner: spawn,
        readDirectories: directories,
        workspaceRoot: workspace.path,
        executableSearchPath: '/usr/bin:/bin');
    expect(
        await gate.run(request(
            '/bin/sh', ['-c', "grep -n 'needle' '${source.path}'"], workspace)),
        isA<CommandCompleted>());
    expect(spawn.calls.single.command, endsWith('/grep'));
    expect(spawn.calls.single.arguments, ['-n', 'needle', source.path]);
    for (final script in [
      "grep needle '${source.path}' > written",
      "grep needle '${source.path}'; touch written",
      "grep needle '${source.path}' | cat",
      r'grep "$HOME" file',
      r'grep `touch written` file',
      r'grep $(touch written) file',
      'grep needle *',
      "grep needle '${source.path}'\ntouch written",
      "env grep needle '${source.path}'",
      "grep --unknown '${source.path}'",
    ]) {
      expect(await gate.run(request('/bin/sh', ['-c', script], workspace)),
          isA<CommandRefused>(),
          reason: script);
    }
    expect(spawn.calls, hasLength(1));
  }, skip: Platform.isWindows);

  test('approval checkbox persists reads without an execution or write grant',
      () async {
    final catalog = SettingCatalog()..register(readOnlyDirectoriesSetting);
    final backend = MemorySettingsBackend();
    final settings = ScopedSettings(catalog: catalog, backend: backend);
    final tools = ToolsPlugin(
        workspaceRoot: workspace.path,
        tinaDir: Directory('${workspace.path}/.tina'),
        settings: settings);
    final approvals = ReadApprovals();
    tools.modePolicy.approvals = approvals;
    final exec =
        tools.toolList.singleWhere((tool) => tool.schema.name == 'exec');
    final args = {
      'program': 'grep',
      'args': ['-n', 'needle', source.path]
    };
    final first = await exec.execute(args);
    expect(first.isError, isFalse, reason: first.content);
    expect(approvals.details.single['read_directory'],
        external.resolveSymbolicLinksSync());
    expect(tools.readDirectories.allows(source.resolveSymbolicLinksSync()),
        isTrue);
    expect(tools.processRunner.grants.isEmpty, isTrue);
    final second = await exec.execute(args);
    expect(second.isError, isFalse, reason: second.content);
    expect(approvals.details, hasLength(1));
    final reloaded = ScopedSettings(catalog: catalog, backend: backend);
    expect(reloaded.read(readOnlyDirectoriesSetting).value,
        [external.resolveSymbolicLinksSync()]);
    final write =
        tools.toolList.singleWhere((tool) => tool.schema.name == 'write');
    approvals.decision = ApprovalDecision.deny;
    expect(
        (await write.execute({'filePath': source.path, 'content': 'changed'}))
            .isError,
        isTrue);
    expect(approvals.details.last, isNot(contains('read_directory')));
    expect(source.readAsStringSync(), 'needle\n');
    settings.set(readOnlyDirectoriesSetting, <String>[], SettingScope.global);
    expect(tools.readDirectories.paths, isEmpty);
    expect((await exec.execute(args)).isError, isTrue);
    tools.closeSession();
    settings.close();
    reloaded.close();
  }, skip: Platform.isWindows);

  test('directory settings validate paths and preserve a workspace override',
      () async {
    expect(() => readOnlyDirectoriesSetting.checked(['relative']),
        throwsFormatException);
    final catalog = SettingCatalog()..register(readOnlyDirectoriesSetting);
    final settings =
        ScopedSettings(catalog: catalog, backend: MemorySettingsBackend());
    settings.set(
        readOnlyDirectoriesSetting, [external.path], SettingScope.workspace);
    final tools = ToolsPlugin(
        workspaceRoot: workspace.path,
        tinaDir: Directory('${workspace.path}/.tina'),
        settings: settings);
    tools.rememberReadDirectory(other.resolveSymbolicLinksSync());
    expect(settings.read(readOnlyDirectoriesSetting).source,
        SettingScope.workspace);
    expect(settings.layer(SettingScope.global), isEmpty);
    expect(tools.readDirectories.paths, hasLength(2));
    tools.closeSession();
    settings.close();
  });
}

final class ReadApprovals implements ApprovalRequester {
  ApprovalDecision decision = ApprovalDecision.allowReadsInDirectory;
  final details = <Map<String, Object?>>[];
  @override
  Future<ApprovalDecision> request(
      {required String operation,
      required String target,
      required String reason,
      ApprovalKind kind = ApprovalKind.permission,
      Map<String, Object?> details = const {}}) async {
    this.details.add(details);
    return decision;
  }
}
