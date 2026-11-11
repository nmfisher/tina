import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_settings/tina_settings.dart';
import 'package:tina_tools/tina_tools.dart';
import 'package:tina_approvals/tina_approvals.dart';

final class Recorder implements ConfinedProcessRunner {
  @override
  final bool confinesFilesystem;
  Recorder({this.confinesFilesystem = true});
  final calls = <ProcessRequest>[];
  final controls = <ProcessControl?>[];
  @override
  Future<RunOutcome> run(ProcessRequest request,
      {ProcessControl? control}) async {
    calls.add(request);
    controls.add(control);
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
      Future<void>? whenCancelled,
      Map<String, Object?> details = const {},
      void Function(String pattern)? onCommandPattern,
      void Function(List<DirectoryAccessGrant> grants)?
          onDirectoryGrants}) async {
    this.details.add(details);
    return decision;
  }
}
