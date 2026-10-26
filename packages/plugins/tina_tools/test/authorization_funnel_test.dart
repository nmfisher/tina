import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_tools/tina_tools.dart';

class WorkspaceJudge extends PermissionClassifier {
  WorkspaceJudge() : super(() => throw StateError('unused provider'));
  int calls = 0;
  @override
  Future<PermissionJudgment> classify(Map<String, Object?> request,
      {Future<void>? whenCancelled}) async {
    calls++;
    return const PermissionJudgment(true, 'workspace work');
  }
}

void main() {
  late Directory root, workspace, external;
  late StreamApprovalChannel channel;
  late ApprovalsPlugin approvals;
  late ToolsPlugin tools;
  final requests = <ApprovalRequest>[];
  setUp(() {
    root = Directory.systemTemp.createTempSync('authorization_funnel_');
    workspace = Directory('${root.path}/workspace')..createSync();
    external = Directory('${root.path}/external')..createSync();
    File('${workspace.path}/input.txt').writeAsStringSync('workspace data\n');
    File('${external.path}/secret.txt').writeAsStringSync('external data\n');
    channel = StreamApprovalChannel();
    approvals = ApprovalsPlugin(channel: channel);
    requests.clear();
    channel.requests.listen((request) {
      requests.add(request);
      channel.respond(request.id, ApprovalDecision.deny);
    });
    tools = ToolsPlugin(
      workspaceRoot: workspace.path,
      tinaDir: Directory('${workspace.path}/.tina'),
      mode: PermissionMode.readOnly,
      hostEnvironment: {
        'HOME': root.path,
        'PATH': '/usr/bin:/bin',
        'LANG': 'C.UTF-8'
      },
    );
    tools.modePolicy.approvals = approvals;
  });
  tearDown(() async {
    tools.closeSession();
    approvals.closeSession();
    await tools.processJobs.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  });
  test('all modes permit workspace file reads and ask for external reads',
      () async {
    final read =
        tools.toolList.singleWhere((tool) => tool.schema.name == 'read');
    for (final mode
        in PermissionMode.values.where((m) => m != PermissionMode.yolo)) {
      tools.mode = mode;
      final inside =
          await read.execute({'filePath': '${workspace.path}/input.txt'});
      expect(inside.isError, false, reason: inside.content);
      final before = requests.length;
      final outside =
          await read.execute({'filePath': '${external.path}/secret.txt'});
      expect(outside.isError, true);
      expect(requests.length, before + 1,
          reason: '$mode external read must ask a human');
    }
  });
  test('read-only blocks writes even with an exact remembered grant', () async {
    final file = File('${workspace.path}/input.txt');
    tools.sandbox.grants.rememberExact(file.resolveSymbolicLinksSync());
    final write =
        tools.toolList.singleWhere((tool) => tool.schema.name == 'write');
    final result =
        await write.execute({'filePath': file.path, 'content': 'changed'});
    expect(result.isError, true);
    expect(file.readAsStringSync(), 'workspace data\n');
    expect(requests, isEmpty);
  });
  for (final mode in [
    PermissionMode.ask,
    PermissionMode.auto,
    PermissionMode.readOnly,
  ]) {
    test('$mode inspects workspace Git and shell scripts without prompting',
        () async {
      tools.mode = mode;
      final judge = WorkspaceJudge();
      tools.modePolicy.classifier = judge;
      Future<void> git(List<String> args) async {
        final result = await Process.run('/usr/bin/git', args,
            workingDirectory: workspace.path);
        expect(result.exitCode, 0,
            reason: '${result.stdout}\n${result.stderr}');
      }

      await git(['init', '-q']);
      await git(['add', 'input.txt']);
      await git([
        '-c',
        'user.name=Fixture',
        '-c',
        'user.email=fixture@example.invalid',
        'commit',
        '-qm',
        'workspace fixture',
      ]);
      final exec = tools.toolList.singleWhere((t) => t.schema.name == 'exec');
      final bash = tools.toolList.singleWhere((t) => t.schema.name == 'bash');
      for (final args in [
        ['status', '--short'],
        ['log', '-n', '1', '--format=%s'],
        ['-C', workspace.path, 'status', '--porcelain'],
        ['--no-pager', 'log', '-1', '--oneline'],
      ]) {
        final result = await exec.execute({'program': 'git', 'args': args});
        expect(result.isError, false, reason: 'git $args: ${result.content}');
      }
      final script = await bash.execute({
        'command': 'git -C "${workspace.path}" log -n 1 --format=%s | '
            'head -n 1; for file in *.txt; do cat "\$file"; done',
      });
      expect(script.isError, false, reason: script.content);
      expect(script.content, contains('workspace fixture'));
      expect(script.content, contains('workspace data'));
      expect(requests, isEmpty);
      expect(judge.calls, 0, reason: 'workspace reads need no AI review');
    }, skip: !Platform.isMacOS && !Platform.isLinux);
  }
  test('default read access cannot mutate files or replace a write approval',
      () async {
    tools.mode = PermissionMode.ask;
    final bash = tools.toolList.singleWhere((t) => t.schema.name == 'bash');
    final blocked =
        await bash.execute({'command': 'printf changed > input.txt'});
    expect(blocked.isError, true);
    expect(requests, isEmpty);
    expect(File('${workspace.path}/input.txt').readAsStringSync(),
        'workspace data\n');
    final denied = await bash.execute({
      'command': 'printf changed > input.txt',
      'access': 'workspace-write',
    });
    expect(denied.isError, true);
    expect(requests, hasLength(1));
    expect(File('${workspace.path}/input.txt').readAsStringSync(),
        'workspace data\n');
  }, skip: !Platform.isMacOS && !Platform.isLinux);
  test('default command reads still ask for external paths and network',
      () async {
    tools.mode = PermissionMode.ask;
    final exec = tools.toolList.singleWhere((t) => t.schema.name == 'exec');
    Link('${workspace.path}/outside').createSync(external.path);
    final denied = await exec.execute({
      'program': 'cat',
      'args': ['${workspace.path}/outside/secret.txt'],
    });
    expect(denied.isError, true);
    expect(requests, hasLength(1));
    final network = await exec.execute({
      'program': 'git',
      'args': ['--version'],
      'network': true,
      'network_reason': 'test the approval boundary',
    });
    expect(network.isError, true);
    expect(requests, hasLength(2));
    expect(requests.last.details['missing_permissions'], ['network']);
  }, skip: !Platform.isMacOS && !Platform.isLinux);
  for (final mode in [PermissionMode.ask, PermissionMode.auto]) {
    test(
        '$mode cannot read external data through an unrecognized shell command',
        () async {
      tools.mode = mode;
      final judge = WorkspaceJudge();
      tools.modePolicy.classifier = judge;
      Link('${workspace.path}/outside').createSync(external.path);
      final bash = tools.toolList.singleWhere((t) => t.schema.name == 'bash');
      final result = await bash.execute({
        'command': r'cat "$PWD/outside/secret.txt"',
      });
      expect(result.isError, true);
      expect(result.content, isNot(contains('external data')));
      expect(judge.calls, 0, reason: 'the AI cannot authorize external reads');
    }, skip: !Platform.isMacOS && !Platform.isLinux);
  }
  test(
      'symlinks inside the workspace require approval for their resolved target',
      () async {
    Link('${workspace.path}/outside').createSync(external.path);
    final read =
        tools.toolList.singleWhere((tool) => tool.schema.name == 'read');
    final result = await read
        .execute({'filePath': '${workspace.path}/outside/secret.txt'});
    expect(result.isError, true);
    expect(requests.single.target, contains('/external/secret.txt'));
  }, skip: Platform.isWindows);
  test(
      'arbitrary read-only scripts run freely while workspace writes are blocked',
      () async {
    final bash =
        tools.toolList.singleWhere((tool) => tool.schema.name == 'bash');
    final read = await bash.execute({
      'command': r'for file in *.txt; do cat "$file"; done',
      'access': 'read-only'
    });
    expect(read.isError, false, reason: read.content);
    expect(read.content, contains('workspace data'));
    final write = await bash.execute(
        {'command': 'printf changed > input.txt', 'access': 'read-only'});
    expect(write.isError, true);
    expect(File('${workspace.path}/input.txt').readAsStringSync(),
        'workspace data\n');
    expect(requests, isEmpty);
    final scratch = await bash.execute({
      'command': r'printf scratch > "$TMPDIR/result"; cat "$TMPDIR/result"',
      'access': 'read-only'
    });
    expect(scratch.isError, false, reason: scratch.content);
    expect(scratch.content, contains('scratch'));
  }, skip: !Platform.isMacOS && !Platform.isLinux);
  test('allow-edits runs a workspace-writing script without approval',
      () async {
    tools.mode = PermissionMode.allowEdits;
    final bash =
        tools.toolList.singleWhere((tool) => tool.schema.name == 'bash');
    final result = await bash.execute(
        {'command': 'printf changed > input.txt', 'access': 'workspace-write'});
    expect(result.isError, false, reason: result.content);
    expect(File('${workspace.path}/input.txt').readAsStringSync(), 'changed');
    expect(requests, isEmpty);
  }, skip: !Platform.isMacOS && !Platform.isLinux);
  test('changing mode cancels a started workspace-writing job', () async {
    tools.mode = PermissionMode.allowEdits;
    final bash =
        tools.toolList.singleWhere((tool) => tool.schema.name == 'bash');
    final started = await bash.execute({
      'command': 'echo started; sleep 30; printf changed > input.txt',
      'access': 'workspace-write',
      'background': true,
    });
    expect(started.isError, false, reason: started.content);
    final id =
        RegExp(r'Job ID: ([^ .\n]+)').firstMatch(started.content)!.group(1)!;
    tools.mode = PermissionMode.readOnly;
    final stopped = await tools.processJobs
        .inspect({'job_id': id, 'action': 'wait', 'wait_ms': 3000});
    expect(stopped.isError, true);
    expect(stopped.content, contains('cancelled'));
    expect(File('${workspace.path}/input.txt').readAsStringSync(),
        'workspace data\n');
  }, skip: !Platform.isMacOS && !Platform.isLinux);
  test(
      'auto reviews workspace changes when external capabilities already have a human grant',
      () async {
    final judge = WorkspaceJudge();
    tools.mode = PermissionMode.auto;
    tools.modePolicy.classifier = judge;
    final request = (
      command: '/usr/bin/printf',
      arguments: ['workspace analysis'],
      workingDirectory: workspace.path,
      environment: null,
      stdin: null,
      timeout: null,
    );
    tools.commandApprovals.remember(
        request, {ProcessPermission.network}, CommandApprovalScope.session);
    final result = await tools.processRunner.run(request,
        control: const ProcessControl(
          readOnlyRequested: false,
          networkRequested: true,
          networkReason: 'already approved',
        ));
    expect(result, isA<CommandCompleted>());
    expect((result as CommandCompleted).exitCode, 0, reason: result.stderr);
    expect(judge.calls, 1);
    expect(requests, isEmpty,
        reason: 'only the uncovered workspace capability needs review');
  }, skip: !Platform.isMacOS && !Platform.isLinux);
}
