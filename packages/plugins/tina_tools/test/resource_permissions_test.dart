import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_tools/tina_tools.dart';

class Judge extends PermissionClassifier {
  Judge(this.answer) : super(() => throw StateError('unused provider'));
  PermissionJudgment answer;
  final requests = <Map<String, Object?>>[];
  @override
  Future<PermissionJudgment> classify(Map<String, Object?> request,
      {Future<void>? whenCancelled}) async {
    requests.add(request);
    return answer;
  }
}

class Recorder implements ConfinedProcessRunner {
  @override
  bool get confinesFilesystem => true;
  final requests = <ProcessRequest>[];
  final controls = <ProcessControl?>[];
  RunOutcome outcome =
      const CommandCompleted(exitCode: 0, stdout: '', stderr: '');
  @override
  Future<RunOutcome> run(ProcessRequest request,
      {ProcessControl? control}) async {
    requests.add(request);
    controls.add(control);
    return outcome;
  }
}

void main() {
  late Directory fixture, workspace, home, external;
  late ToolsPlugin plugin;
  late StreamApprovalChannel channel;
  late ApprovalsPlugin approvals;
  late Judge judge;
  final asks = <ApprovalRequest>[];
  var decision = ApprovalDecision.allow;
  List<DirectoryAccessGrant> Function(ApprovalRequest)? saved;

  setUp(() {
    fixture = Directory(Directory.systemTemp
        .createTempSync('resource-policy-')
        .resolveSymbolicLinksSync());
    workspace = Directory('${fixture.path}/project')..createSync();
    home = Directory('${fixture.path}/home')..createSync();
    external = Directory('${fixture.path}/external')..createSync();
    plugin = ToolsPlugin(
        workspaceRoot: workspace.path,
        tinaDir: Directory('${workspace.path}/.tina'),
        hostEnvironment: {'HOME': home.path, 'PATH': '/usr/bin:/bin'});
    judge = Judge(const PermissionJudgment(true));
    channel = StreamApprovalChannel();
    approvals = ApprovalsPlugin(channel: channel);
    plugin.modePolicy.approvals = approvals;
    plugin.modePolicy.classifier = judge;
    asks.clear();
    decision = ApprovalDecision.allow;
    saved = null;
    final subscription = channel.requests.listen((request) {
      asks.add(request);
      channel.respond(request.id, decision,
          directoryGrants: saved?.call(request) ?? const []);
    });
    addTearDown(subscription.cancel);
    addTearDown(plugin.closeSession);
    addTearDown(approvals.closeSession);
    addTearDown(channel.closeSession);
    addTearDown(() => fixture.deleteSync(recursive: true));
  });

  test('MCP grants remain separate from obsolete filesystem access grants', () {
    plugin.commandApprovals.rememberAccess(
        'read', 'server/resource', CommandApprovalScope.session);
    plugin.commandApprovals.rememberAccess(
        'read', '${external.path}/old-file', CommandApprovalScope.session);
    expect(
        plugin.commandApprovals.coversAccess('read', 'server/resource'), true);
    expect(
        plugin.commandApprovals
            .coversAccess('read', '${external.path}/old-file'),
        false);
    expect(plugin.commandApprovals.entries, hasLength(1));
    final child = ToolsPlugin(
        workspaceRoot: workspace.path,
        tinaDir: Directory('${workspace.path}/.tina'),
        approvalStore: plugin.commandApprovals,
        hostEnvironment: {'HOME': home.path});
    addTearDown(child.closeSession);
    expect(
        child.commandApprovals.coversAccess('read', 'server/resource'), true);
    expect(identical(child.pathGrants, plugin.pathGrants), true);
  });

  test('workspace reads are unconditional in both modes', () async {
    File('${workspace.path}/source').writeAsStringSync('hello');
    for (final mode in [PermissionMode.approve, PermissionMode.auto]) {
      plugin.mode = mode;
      expect(await plugin.sandbox.readFileString('${workspace.path}/source'),
          'hello');
    }
    expect(asks, isEmpty);
    expect(judge.requests, isEmpty);
  });

  test('first write is human-only and authorizes the entire workspace',
      () async {
    plugin.mode = PermissionMode.auto;
    await plugin.sandbox.writeFile('${workspace.path}/one', '1');
    await plugin.sandbox.writeFile('${workspace.path}/two', '2');
    plugin.mode = PermissionMode.approve;
    await plugin.sandbox.delete('${workspace.path}/one');
    expect(asks, hasLength(1));
    expect(asks.single.details['workspace_write_grant'], isTrue);
    expect(asks.single.target, workspace.path);
    expect(judge.requests, isEmpty);
  });

  test('denying first write keeps the workspace read-only', () async {
    decision = ApprovalDecision.deny;
    await expectLater(plugin.sandbox.writeFile('${workspace.path}/one', '1'),
        throwsA(isA<SandboxViolation>()));
    expect(File('${workspace.path}/one').existsSync(), isFalse);
    expect(plugin.modePolicy.hasWorkspaceWriteGrant(workspace.path), isFalse);
  });

  test('simultaneous workspace writes share one approval', () async {
    await Future.wait([
      plugin.sandbox.writeFile('${workspace.path}/one', '1'),
      plugin.sandbox.writeFile('${workspace.path}/two', '2'),
    ]);
    expect(asks, hasLength(1));
  });

  test('workspace grant is session-only and shared with child policy',
      () async {
    await plugin.sandbox.writeFile('${workspace.path}/one', '1');
    final child = ModePlugin()..inheritPolicy(plugin.modePolicy);
    addTearDown(child.closeSession);
    expect(child.hasWorkspaceWriteGrant(workspace.path), isTrue);
    expect(ModePlugin().hasWorkspaceWriteGrant(workspace.path), isFalse);
  });

  test('external file read can be remembered without granting its sibling',
      () async {
    final target = File('${external.path}/one')..writeAsStringSync('1');
    final other = File('${external.path}/two')..writeAsStringSync('2');
    saved = (_) => [
          DirectoryAccessGrant(
              target.path, DirectoryAccess.read, DirectoryGrantScope.workspace,
              recursive: false)
        ];
    expect(await plugin.sandbox.readFileString(target.path), '1');
    saved = null;
    expect(await plugin.sandbox.readFileString(target.path), '1');
    expect(asks, hasLength(1));
    final fresh = PathGrants(file: plugin.pathGrants.file);
    expect(fresh.allows(target.path), isTrue);
    expect(fresh.allows(other.path), isFalse);
    expect(fresh.allows(target.path, write: true), isFalse);
    expect(await plugin.sandbox.readFileString(other.path), '2');
    expect(asks, hasLength(2));
  });

  test('saved external directory read-write covers descendants but not delete',
      () async {
    final target = '${external.path}/one';
    saved = (_) => [
          DirectoryAccessGrant(external.path, DirectoryAccess.write,
              DirectoryGrantScope.workspace)
        ];
    await plugin.sandbox.writeFile(target, '1');
    saved = null;
    await plugin.sandbox.writeFile('${external.path}/two', '2');
    expect(await plugin.sandbox.readFileString(target), '1');
    expect(asks, hasLength(1));
    decision = ApprovalDecision.deny;
    await expectLater(
        plugin.sandbox.delete(target), throwsA(isA<SandboxViolation>()));
    expect(asks, hasLength(2));
  });

  test('auto approval is invocation-only and never saved', () async {
    plugin.mode = PermissionMode.auto;
    final target = File('${external.path}/one')..writeAsStringSync('1');
    await plugin.sandbox.readFileString(target.path);
    await plugin.sandbox.readFileString(target.path);
    expect(judge.requests, hasLength(2));
    expect(asks, isEmpty);
    expect(plugin.pathGrants.grants, isEmpty);
    expect(plugin.pathGrants.file!.existsSync(), isFalse);
  });

  test('auto denial blocks access; uncertainty asks the human', () async {
    plugin.mode = PermissionMode.auto;
    final target = File('${external.path}/secret')
      ..writeAsStringSync('private');
    judge.answer = const PermissionJudgment.denied('accesses a secret');
    await expectLater(plugin.sandbox.readFileString(target.path),
        throwsA(isA<SandboxViolation>()));
    expect(asks, isEmpty);
    judge.answer = const PermissionJudgment(null, 'uncertain');
    expect(await plugin.sandbox.readFileString(target.path), 'private');
    expect(asks, hasLength(1));
  });

  test('symlinks escaping workspace request external approval', () async {
    final target = File('${external.path}/one')..writeAsStringSync('1');
    Link('${workspace.path}/link').createSync(target.path);
    decision = ApprovalDecision.deny;
    await expectLater(plugin.sandbox.readFileString('${workspace.path}/link'),
        throwsA(isA<SandboxViolation>()));
    expect(asks.single.target, target.path);
  });

  test('grant store stays protected after workspace write approval', () async {
    await plugin.sandbox.writeFile('${workspace.path}/one', '1');
    await expectLater(
        plugin.sandbox.writeFile(plugin.pathGrants.file!.path, '{}'),
        throwsA(isA<SandboxViolation>()));
  });

  SandboxedProcessRunner runner(Recorder inner) {
    final value = SandboxedProcessRunner(
        inner: inner,
        plan: plugin.osPlan,
        workspaceRoot: workspace.path,
        mode: plugin.mode,
        executableSearchPath: '/usr/bin:/bin',
        commandApprover: plugin.processRunner.commandApprover);
    value.workspaceWriteGranted =
        () => plugin.modePolicy.hasWorkspaceWriteGrant(workspace.path);
    value.requestWorkspaceWrite =
        () => plugin.modePolicy.ensureWorkspaceWrite(workspace.path);
    return value;
  }

  ProcessRequest command(String executable, [List<String> args = const []]) => (
        command: executable,
        arguments: args,
        workingDirectory: workspace.path,
        environment: null,
        stdin: null,
        timeout: null,
      );

  test('external executable is reviewed on every invocation', () async {
    final inner = Recorder();
    final value = runner(inner);
    await value.run(command('/bin/echo', ['hello']));
    await value.run(command('/bin/echo', ['hello']));
    expect(asks, hasLength(2));
    expect(inner.controls.every((c) => c!.readOnly), isTrue);
  });

  test('system runtime reads have narrow read-only defaults', () {
    for (final target in plugin.osPlan.runtimeReadPaths) {
      if (FileSystemEntity.typeSync(target) == FileSystemEntityType.notFound)
        continue;
      expect(plugin.osPlan.canRead(target), isTrue, reason: target);
      expect(plugin.osPlan.canWrite(target), isFalse, reason: target);
    }
    for (final target in [
      '/usr',
      '/etc',
      '/etc/shadow',
      '/usr/local/private-data',
      '${home.path}/.ssh/id_rsa',
      external.path
    ]) {
      expect(plugin.osPlan.canRead(target), isFalse, reason: target);
    }
    final protected =
        SandboxPlan(workspaceRoot: workspace.path, protectedPaths: ['/bin']);
    expect(protected.canRead('/bin/sh'), isFalse);
    expect(plugin.pathGrants.grants, isEmpty);
  });

  test('shell approval does not offer system runtime directories to remember',
      () async {
    final inner = Recorder();
    expect(await runner(inner).run(command('/bin/sh', ['-c', 'echo hello'])),
        isA<CommandCompleted>());
    expect(asks, hasLength(1));
    expect(asks.single.details['directory_accesses'], isEmpty);
    expect(asks.single.details['accesses'], isEmpty);
    final requirements =
        (asks.single.details['access_requirements'] as List).cast<Map>();
    expect(requirements.any((r) => r['capability'] == 'read'), isFalse);
    expect(requirements.any((r) => r['capability'] == 'execute'), isTrue);
    expect(plugin.pathGrants.grants, isEmpty);
    expect(inner.controls.single!.readOnly, isTrue);
    expect(inner.controls.single!.networkAllowed, isFalse);
  });

  test('file tools share the public runtime read baseline', () async {
    final hosts = File('/etc/hosts');
    if (!hosts.existsSync()) return;
    expect(await plugin.sandbox.readFileString(hosts.path),
        hosts.readAsStringSync());
    expect(asks, isEmpty);
    expect(plugin.pathGrants.grants, isEmpty);
  });

  test('Remember marks only offers covered by the saved access and scope',
      () async {
    final file = File('${external.path}/one')..writeAsStringSync('1');
    plugin.pathGrants.remember(file.path, write: false, recursive: false);
    final value = runner(Recorder());
    await value.run(command('/bin/cat', [file.path]));
    List<Map> offers() =>
        (asks.last.details['directory_accesses'] as List).cast<Map>();
    expect(
        offers().singleWhere((offer) => offer['path'] == file.path)['granted'],
        isTrue);
    expect(
        offers()
            .singleWhere((offer) => offer['path'] == external.path)['granted'],
        isFalse);

    await plugin.sandbox.writeFile(file.path, '2');
    expect(offers().every((offer) => offer['granted'] == false), isTrue,
        reason: 'Saved reads must not check write offers');

    plugin.pathGrants.remember(external.path, write: true, recursive: true);
    await value.run(command('/bin/cat', [file.path]));
    for (final target in [file.path, external.path]) {
      expect(
          offers().singleWhere((offer) => offer['path'] == target)['granted'],
          isTrue,
          reason: 'A saved directory write also covers reads of its children');
    }
  });

  test('file and command writes share the session workspace grant', () async {
    final inner = Recorder();
    final value = runner(inner);
    await value.run(command('/bin/echo'),
        control: const ProcessControl(readOnlyRequested: false));
    expect(asks.where((a) => a.details['workspace_write_grant'] == true),
        hasLength(1));
    await plugin.sandbox.writeFile('${workspace.path}/one', '1');
    expect(asks.where((a) => a.details['workspace_write_grant'] == true),
        hasLength(1));
    expect(inner.controls.single!.workspaceWriteAllowed, isTrue);
    await value.run(command('/bin/echo'),
        control: const ProcessControl(readOnlyRequested: true));
    expect(inner.controls.last!.readOnly, isTrue);
    expect(inner.controls.last!.workspaceWriteAllowed, isFalse);
  });

  test('external writes do not unlock workspace writes', () async {
    final inner = Recorder();
    await runner(inner).run(command('/bin/echo'),
        control: ProcessControl(writeDirectories: [external.path]));
    expect(inner.controls.single!.readOnly, isFalse);
    expect(inner.controls.single!.workspaceWriteAllowed, isFalse);
    expect(plugin.modePolicy.hasWorkspaceWriteGrant(workspace.path), isFalse);
  });

  test('blocked commands are returned without an automatic retry', () async {
    final inner = Recorder()
      ..outcome = CommandBlocked('blocked',
          accessRequests: [SandboxAccessRequest(external.path, write: false)]);
    expect(
        await runner(inner).run(command('/bin/echo')), isA<CommandBlocked>());
    expect(inner.requests, hasLength(1));
  });

  test('saved grants mount exact files with independent workspace access',
      () async {
    final file = File('${external.path}/one')..writeAsStringSync('1');
    plugin.pathGrants.remember(file.path, write: true, recursive: false);
    final inner = Recorder();
    final os = OsSandboxRunner(
        inner: inner,
        plan: plugin.osPlan,
        backend: SandboxBackend.bwrap,
        hostLayout: () => SandboxHostLayout(
            readOnlyDirectories: ['/bin'], temporaryDirectories: []));
    await os.run(command('/bin/echo'),
        control: const ProcessControl(workspaceWriteAllowed: false));
    final argv = inner.requests.single.arguments;
    final fileMount = argv.indexOf(file.path);
    expect(argv[fileMount - 1], '--bind');
    final workspaceMount = argv.indexOf(workspace.path);
    expect(argv[workspaceMount - 1], '--ro-bind');
    expect(argv, isNot(contains(external.path)));
  });

  test('revocation through Settings takes effect in another grant reader',
      () async {
    final target = File('${external.path}/one')..writeAsStringSync('1');
    plugin.pathGrants.remember(target.path, write: false, recursive: false);
    final otherReader = PathGrants(file: plugin.pathGrants.file);
    expect(otherReader.allows(target.path), isTrue);
    final entry = plugin.commandApprovals.entries.single;
    expect(entry['command'], 'Read file');
    plugin.commandApprovals.revoke(entry['id'] as String);
    expect(otherReader.allows(target.path), isFalse);
    decision = ApprovalDecision.deny;
    await expectLater(plugin.sandbox.readFileString(target.path),
        throwsA(isA<SandboxViolation>()));
  });

  test('replacing a saved directory with a symlink cannot redirect its grant',
      () async {
    final granted = Directory('${external.path}/granted')..createSync();
    final outside = Directory('${external.path}/other')..createSync();
    plugin.pathGrants.remember(granted.path, write: true, recursive: true);
    granted.renameSync('${external.path}/original');
    Link(granted.path).createSync(outside.path);
    expect(plugin.pathGrants.allows('${outside.path}/secret'), isFalse);
    expect(
        plugin.pathGrants.allows('${granted.path}/file', write: true), isFalse);
    expect(plugin.osPlan.extraWritablePaths, isNot(contains(granted.path)));
  });

  test('damaged grant files fail closed and are never overwritten', () {
    final file = plugin.pathGrants.file!;
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('{broken');
    expect(plugin.pathGrants.allows(external.path), isFalse);
    expect(
        () => plugin.pathGrants
            .remember(external.path, write: false, recursive: true),
        throwsFormatException);
    expect(file.readAsStringSync(), '{broken');
  });

  test('a forged folder answer cannot widen an exact-file offer', () async {
    final target = File('${external.path}/one')..writeAsStringSync('1');
    saved = (_) => [
          DirectoryAccessGrant(
              target.path, DirectoryAccess.read, DirectoryGrantScope.workspace,
              recursive: true)
        ];
    await expectLater(plugin.sandbox.readFileString(target.path),
        throwsA(isA<SandboxViolation>()));
    expect(plugin.pathGrants.grants, isEmpty);
  });

  test('saved external writes work without granting workspace writes',
      () async {
    plugin.pathGrants.remember(external.path, write: true, recursive: true);
    final script = File('${workspace.path}/tool')..writeAsStringSync('tool');
    final inner = Recorder();
    expect(
        await runner(inner).run(command(script.path)), isA<CommandCompleted>());
    expect(asks, isEmpty);
    expect(inner.controls.single!.readOnly, isFalse);
    expect(inner.controls.single!.workspaceWriteAllowed, isFalse);
  });

  test('network approval never grants workspace writes or future network',
      () async {
    final inner = Recorder();
    final value = runner(inner);
    await value.run(command('/bin/echo'),
        control: const ProcessControl(
            networkRequested: true, networkReason: 'fetch'));
    expect(inner.controls.single!.networkAllowed, isTrue);
    expect(inner.controls.single!.workspaceWriteAllowed, isFalse);
    expect(inner.controls.single!.readOnly, isTrue);
    await value.run(command('/bin/echo'));
    expect(inner.controls.last!.networkAllowed, isFalse);
    expect(asks, hasLength(2));
    expect(plugin.pathGrants.grants, isEmpty);
  });

  test('auto mode reviews host commands before allowing their invocation', () async {
    plugin.mode = PermissionMode.auto;
    final inner = Recorder();
    final value = runner(inner);
    const control = ProcessControl(
        outsideSandboxRequested: true,
        sandboxReason: 'Read authenticated GitHub logs');
    final request = command('/bin/bash', ['-c', 'gh api repos/example/project']);
    expect(await value.run(request, control: control), isA<CommandCompleted>());
    expect(asks, isEmpty);
    expect(judge.requests, hasLength(1));
    expect(judge.requests.single['required_permissions'],
        containsAll(['execution', 'network', 'unconfined']));
    expect(inner.controls.single!.outsideSandboxAllowed, isTrue);
    expect(inner.controls.single!.networkAllowed, isTrue);
    judge.answer = const PermissionJudgment.denied('Accesses a secret.');
    expect(await value.run(request, control: control), isA<CommandRefused>());
    expect(inner.requests, hasLength(1));
    expect(asks, isEmpty);
    expect(judge.requests, hasLength(2));
    judge.answer = const PermissionJudgment(null, 'timed out');
    expect(await value.run(request, control: control), isA<CommandCompleted>());
    expect(asks, hasLength(1));
    expect(plugin.pathGrants.grants, isEmpty);
  });

  test('tool input cannot supply authorization stamps', () async {
    final inner = Recorder();
    decision = ApprovalDecision.deny;
    final result = await runner(inner).run(command('/bin/echo'),
        control: const ProcessControl(
            networkAllowed: true,
            workspaceWriteAllowed: true,
            outsideSandboxAllowed: true));
    expect(result, isA<CommandRefused>());
    expect(inner.requests, isEmpty);
    expect(plugin.modePolicy.hasWorkspaceWriteGrant(workspace.path), isFalse);
  });

  test('workspace executable does not inherit a saved grant for deletion',
      () async {
    plugin.pathGrants.remember(external.path, write: true, recursive: true);
    final inner = Recorder();
    decision = ApprovalDecision.deny;
    final value = runner(inner);
    final result =
        await value.run(command('/bin/rm', ['${external.path}/one']));
    expect(result, isA<CommandRefused>());
    final requirements = asks.single.details['access_requirements'] as List;
    expect(
        requirements
            .any((r) => r['capability'] == 'delete' && r['granted'] == false),
        isTrue);
    expect(inner.requests, isEmpty);
  });
}
