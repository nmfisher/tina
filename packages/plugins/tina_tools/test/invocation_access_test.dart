import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_settings/tina_settings.dart';
import 'package:tina_tools/tina_tools.dart';

class Spawn extends ProcessRunner {
  final requests = <ProcessRequest>[];
  final controls = <ProcessControl?>[];
  Completer<void>? hold;
  @override
  Future<RunOutcome> run(ProcessRequest request,
      {ProcessControl? control}) async {
    requests.add(request);
    controls.add(control);
    control?.onStarted?.call();
    await hold?.future;
    return const CommandCompleted(exitCode: 0, stdout: '', stderr: '');
  }
}

class Judge extends PermissionClassifier {
  Judge(this.result) : super(() => throw StateError('unused'));
  PermissionJudgment result;
  final requests = <Map<String, Object?>>[];
  @override
  Future<PermissionJudgment> classify(Map<String, Object?> request,
      {Future<void>? whenCancelled}) async {
    requests.add(request);
    return result;
  }
}

class Human implements ApprovalRequester {
  ApprovalDecision answer = ApprovalDecision.allow;
  Future<ApprovalDecision> Function()? respond;
  final details = <Map<String, Object?>>[];
  List<DirectoryAccessGrant> grants = [];
  @override
  Future<ApprovalDecision> request(
      {required String operation,
      required String target,
      required String reason,
      ApprovalKind kind = ApprovalKind.permission,
      Future<void>? whenCancelled,
      Map<String, Object?> details = const {},
      void Function(String)? onCommandPattern,
      void Function(List<DirectoryAccessGrant>)? onDirectoryGrants}) async {
    this.details.add(details);
    final decision = await (respond?.call() ?? Future.value(answer));
    if (decision == ApprovalDecision.allow && grants.isNotEmpty) {
      onDirectoryGrants?.call(grants);
    }
    return decision;
  }
}

void main() {
  late Directory root, workspace, home, external, other;
  setUp(() {
    // Deliberately outside shared temporary mounts: the inner sandbox must
    // actually require additional access. No host subprocess runs in this suite.
    root = Directory(Directory.current
        .createTempSync('.invocation-access-')
        .resolveSymbolicLinksSync());
    workspace = Directory('${root.path}/workspace')..createSync();
    home = Directory('${root.path}/home')..createSync();
    external = Directory('${home.path}/external')..createSync();
    other = Directory('${home.path}/other')..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));

  ToolsPlugin plugin({ScopedSettings? settings}) {
    final tools = ToolsPlugin(
        workspaceRoot: workspace.path,
        tinaDir: Directory('${workspace.path}/.tina'),
        mode: PermissionMode.auto,
        settings: settings,
        hostEnvironment: {
          'HOME': home.path,
          'PATH': '/usr/bin:/bin',
          'TMPDIR': Directory.systemTemp.path
        });
    addTearDown(tools.closeSession);
    return tools;
  }

  ProcessRequest command(
          {String program = '/bin/echo', List<String> args = const ['ok']}) =>
      (
        command: program,
        arguments: args,
        workingDirectory: workspace.path,
        environment: null,
        stdin: null,
        timeout: null,
      );

  SandboxedProcessRunner gate(ToolsPlugin tools, Spawn spawn,
      {SandboxBackend backend = SandboxBackend.sandboxExec}) {
    return SandboxedProcessRunner(
      inner:
          OsSandboxRunner(inner: spawn, plan: tools.osPlan, backend: backend),
      plan: tools.osPlan,
      mode: tools.mode,
      workspaceRoot: workspace.path,
      readDirectories: tools.readDirectories,
      executableSearchPath: '/usr/bin:/bin',
      commandApprover: tools.processRunner.commandApprover,
    );
  }

  test('external data reads require the same approval on macOS and Linux',
      () async {
    final tools = plugin();
    final human = Human()..answer = ApprovalDecision.deny;
    tools.modePolicy.approvals = human;
    final outsideHome = Directory('${root.path}/outside-home')..createSync();
    final plan = tools.osPlan;
    expect(plan.canRead(outsideHome.path, backend: SandboxBackend.sandboxExec),
        false);
    expect(
        plan.canRead(outsideHome.path, backend: SandboxBackend.bwrap), false);
    expect(plan.canRead(external.path, backend: SandboxBackend.sandboxExec),
        false);
    final spawn = Spawn();
    expect(
        await gate(tools, spawn)
            .run(command(program: '/bin/ls', args: [outsideHome.path])),
        isA<CommandRefused>());
    expect(human.details, hasLength(1));
    expect(spawn.requests, isEmpty);
  });

  for (final backend in [SandboxBackend.sandboxExec, SandboxBackend.bwrap]) {
    test(
        '$backend applies human-approved directory access only to this invocation',
        () async {
      final tools = plugin();
      final judge = Judge(const PermissionJudgment(true));
      final human = Human();
      tools.modePolicy
        ..classifier = judge
        ..approvals = human;
      final spawn = Spawn();
      final runner = gate(tools, spawn, backend: backend);
      final request =
          command(program: '/bin/sh', args: ['-c', 'project-build']);
      final outcome = await runner.run(request,
          control: ProcessControl(
            readDirectories: [other.path],
            writeDirectories: [external.path],
            networkRequested: true,
            networkReason: 'dependencies',
          ));
      expect(outcome, isA<CommandCompleted>());
      expect(judge.requests, isEmpty);
      expect(human.details.single['required_permissions'],
          containsAll(['execution', 'network', 'directoryAccess']));
      expect(human.details.single['invocation_directory_access'], {
        'read': [other.path],
        'write': [external.path]
      });
      expect(human.details, hasLength(1));
      expect(tools.readDirectories.paths, isEmpty);
      expect(tools.writeDirectories.paths, isEmpty);
      expect(
          spawn.requests.single.arguments.join(' '), contains(external.path));
      expect(spawn.requests.single.arguments.join(' '), contains(other.path));
      expect(spawn.controls.single!.outsideSandboxAllowed, false);
      expect(spawn.controls.single!.networkAllowed, true);
      expect(await runner.run(command()), isA<CommandCompleted>());
      expect(spawn.controls.last!.approvedDirectories!.isEmpty, true);
      expect(spawn.requests.last.arguments.join(' '),
          isNot(contains(external.path)));
      expect(spawn.controls.last!.networkAllowed, false);
      expect(tools.osPlan.canWrite(external.path), false);
    });
  }

  test('all known reader directories are reviewed together before spawning',
      () async {
    final a = File('${external.path}/a')..writeAsStringSync('a');
    final b = File('${other.path}/b')..writeAsStringSync('b');
    final tools = plugin();
    final human = Human();
    tools.modePolicy.approvals = human;
    final spawn = Spawn();
    final outcome = await gate(tools, spawn)
        .run(command(program: '/bin/cat', args: [a.path, b.path]));
    expect(outcome, isA<CommandCompleted>());
    expect(human.details, hasLength(1));
    expect(human.details.single['invocation_directory_access'], {
      'read': [external.path, other.path]..sort(),
      'write': []
    });
    expect(human.details.single['access_coverage'], 'complete');
    expect(spawn.requests, hasLength(1));
    expect(
        tools.modePolicy.approvalRequestCounts['missing_directory_access'], 1);
  });

  test('temporary read access never creates writable mounts', () async {
    final tools = plugin();
    tools.modePolicy.approvals = Human();
    final spawn = Spawn();
    await gate(tools, spawn, backend: SandboxBackend.bwrap).run(command(),
        control: ProcessControl(readDirectories: [external.path]));
    final args = spawn.requests.single.arguments;
    final index = args.indexOf(external.path);
    expect(args[index - 1], '--ro-bind');
    expect(spawn.controls.single!.approvedDirectories!.write, isEmpty);
  });

  test(
      'session folder grant covers new filenames and revocation affects next call',
      () async {
    final tools = plugin();
    final human = Human()
      ..grants = [
        DirectoryAccessGrant(
            external.path, DirectoryAccess.write, DirectoryGrantScope.session)
      ];
    tools.modePolicy.approvals = human;
    final runner = gate(tools, Spawn());
    final control = ProcessControl(writeDirectories: [external.path]);
    expect(await runner.run(command(args: ['first']), control: control),
        isA<CommandCompleted>());
    expect(tools.writeDirectories.paths, [external.path]);
    human.answer = ApprovalDecision.deny;
    expect(await runner.run(command(args: ['second']), control: control),
        isA<CommandCompleted>());
    expect(human.details, hasLength(1));
    tools.writeDirectories.replace([]);
    expect(await runner.run(command(args: ['third']), control: control),
        isA<CommandRefused>());
    expect(human.details, hasLength(2));
  });

  test(
      'workspace folder grants survive rebuilding the session from saved settings',
      () async {
    final backend = MemorySettingsBackend();
    final catalog = SettingCatalog()
      ..register(readOnlyDirectoriesSetting)
      ..register(writeDirectoriesSetting);
    ScopedSettings settings() {
      final value = ScopedSettings(catalog: catalog, backend: backend);
      addTearDown(value.close);
      return value;
    }

    final tools = plugin(settings: settings());
    final human = Human()
      ..grants = [
        DirectoryAccessGrant(
            external.path, DirectoryAccess.write, DirectoryGrantScope.workspace)
      ];
    tools.modePolicy.approvals = human;
    final control = ProcessControl(writeDirectories: [external.path]);
    expect(await gate(tools, Spawn()).run(command(), control: control),
        isA<CommandCompleted>());
    final resumed = plugin(settings: settings());
    final denied = Human()..answer = ApprovalDecision.deny;
    resumed.modePolicy.approvals = denied;
    expect(
        await gate(resumed, Spawn())
            .run(command(args: ['resumed']), control: control),
        isA<CommandCompleted>());
    expect(denied.details, isEmpty);
  });

  test(
      'Always grants cannot cover a different directory or read-to-write upgrade',
      () async {
    final tools = plugin();
    final human = Human()..answer = ApprovalDecision.allowAlways;
    tools.modePolicy.approvals = human;
    final runner = gate(tools, Spawn());
    final read = ProcessControl(readDirectories: [external.path]);
    await runner.run(command(), control: read);
    await runner.run(command(), control: read);
    expect(human.details, hasLength(1));
    human.answer = ApprovalDecision.deny;
    expect(
        await runner.run(command(),
            control: ProcessControl(writeDirectories: [external.path])),
        isA<CommandRefused>());
    expect(
        await runner.run(command(),
            control: ProcessControl(readDirectories: [other.path])),
        isA<CommandRefused>());
    expect(human.details, hasLength(3));
  });

  test('persistent command rules retain directory capabilities across restart',
      () {
    final file = File('${root.path}/grants/commands.json');
    final store = CommandApprovalStore(workspace: workspace.path, file: file);
    final permissions = {
      ProcessPermission.execution,
      ProcessPermission.directoryAccess
    };
    final access = ProcessDirectoryAccess(read: [external.path]);
    store.remember(command(), permissions, CommandApprovalScope.workspace,
        directoryAccess: access);
    final resumed = CommandApprovalStore(workspace: workspace.path, file: file);
    expect(
        resumed.covers(command(), permissions, directoryAccess: access), true);
    expect(
        resumed.covers(command(), permissions,
            directoryAccess: ProcessDirectoryAccess(write: [external.path])),
        false);
    expect(
        resumed.covers(command(), permissions,
            directoryAccess: ProcessDirectoryAccess(read: [other.path])),
        false);
    expect(
        resumed.covers(command(), {...permissions, ProcessPermission.network},
            directoryAccess: access),
        false);
    resumed.revoke(resumed.entries.single['id'] as String);
    expect(
        store.covers(command(), permissions, directoryAccess: access), false);
  });

  test('changed symlinks and cancellation install no late grants or processes',
      () async {
    final alias = Link('${root.path}/alias')..createSync(external.path);
    final tools = plugin();
    final human = Human();
    tools.modePolicy.approvals = human;
    final spawn = Spawn();
    final runner = gate(tools, spawn);
    human.respond = () async {
      alias.deleteSync();
      alias.createSync(other.path);
      return ApprovalDecision.allowAlways;
    };
    expect(
        await runner.run(command(),
            control: ProcessControl(writeDirectories: [alias.path])),
        isA<CommandRefused>());
    expect(spawn.requests, isEmpty);
    expect(runner.grants.isEmpty, true);
    final cancel = Completer<void>();
    final answer = Completer<ApprovalDecision>();
    human.respond = () => answer.future;
    final pending = runner.run(command(),
        control: ProcessControl(
            writeDirectories: [external.path], whenCancelled: cancel.future));
    await Future<void>.delayed(Duration.zero);
    cancel.complete();
    expect(await pending, isA<CommandRefused>());
    answer.complete(ApprovalDecision.allowAlways);
    await Future<void>.delayed(Duration.zero);
    expect(spawn.requests, isEmpty);
    expect(runner.grants.isEmpty, true);
  });

  test(
      'protected, home-wide and root-wide directory requests fail before review',
      () async {
    final secret = Directory('${home.path}/.ssh')..createSync();
    final tools = plugin();
    final judge = Judge(const PermissionJudgment(true));
    tools.modePolicy.classifier = judge;
    final spawn = Spawn();
    final runner = gate(tools, spawn);
    for (final directory in [secret.path, home.path, '/']) {
      expect(
          await runner.run(command(),
              control: ProcessControl(readDirectories: [directory])),
          isA<CommandRefused>());
    }
    expect(judge.requests, isEmpty);
    expect(spawn.requests, isEmpty);
  });

  test('parallel invocation layouts never inherit each other\'s access',
      () async {
    final tools = plugin();
    tools.modePolicy.approvals = Human();
    tools.modePolicy.classifier = Judge(const PermissionJudgment(true));
    final spawn = Spawn()..hold = Completer<void>();
    final runner = gate(tools, spawn);
    final first = runner.run(command(),
        control: ProcessControl(writeDirectories: [external.path]));
    final second = runner.run(command(),
        control: ProcessControl(writeDirectories: [other.path]));
    while (spawn.requests.length < 2) {
      await Future<void>.delayed(Duration.zero);
    }
    expect(
        spawn.controls.map((c) => c!.approvedDirectories!.write),
        unorderedEquals([
          [external.path],
          [other.path]
        ]));
    expect(tools.writeDirectories.paths, isEmpty);
    spawn.hold!.complete();
    expect(await first, isA<CommandCompleted>());
    expect(await second, isA<CommandCompleted>());
  });

  test('real command adapter supplies verified coverage for precedent reuse',
      () async {
    final file = File('${workspace.path}/source')..writeAsStringSync('read');
    final tools = plugin();
    final human = Human();
    final judge = Judge(const PermissionJudgment(null, 'test unavailable'));
    tools.modePolicy
      ..approvals = human
      ..classifier = judge
      ..precedentStore = MemoryPrecedentStore()
      ..precedentScope = (() => PrecedentScope(workspace: workspace.path))
      ..readPrecedentMode = (() => PrecedentMode.full);
    final request = command(program: '/bin/cat', args: [file.path]);
    final review = CommandApproval(
        reason: 'review',
        requiredPermissions: {ProcessPermission.execution},
        missingPermissions: {ProcessPermission.execution});
    for (var i = 0; i < 3; i++) {
      expect(await tools.processRunner.commandApprover!(request, review),
          Approval.yes);
    }
    expect(human.details, hasLength(2));
    expect(judge.requests, hasLength(2));
    expect(judge.requests.first['access_coverage'], 'complete');
    expect(judge.requests.first['access_coverage_source'], 'verified');
  });

  test(
      'exec/bash and background jobs preserve requests and reset supplied authority',
      () async {
    for (final shell in [false, true]) {
      final capture = Spawn();
      final jobs = ProcessJobs(capture);
      addTearDown(jobs.close);
      final tool = shell ? BashTool(runner: jobs) : ExecTool(runner: jobs);
      final input = <String, dynamic>{
        if (shell) 'command': 'echo ok' else 'program': '/bin/echo',
        'read_directories': [external.path],
        'write_directories': [other.path],
      };
      await tool.execute(input,
          control: ProcessControl(
              approvedDirectories: ProcessDirectoryAccess(write: [home.path])));
      expect(capture.controls.single!.readDirectories, [external.path]);
      expect(capture.controls.single!.writeDirectories, [other.path]);
      expect(capture.controls.single!.approvedDirectories, isNull);
      expect(
          (await tool.execute({...input, 'read_directories': 'bad'})).isError,
          true);
    }
  });
}
