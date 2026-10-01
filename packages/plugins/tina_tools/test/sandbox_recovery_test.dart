import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_tools/tina_tools.dart';

import 'process_permissions_test.dart' show command, RecordingRunner;

const outside = ProcessControl(
    outsideSandboxRequested: true, sandboxReason: 'host executable is hidden');

void main() {
  for (final mode in PermissionMode.values) {
    test('$mode requires separate confinement approval after execution/network',
        () async {
      final inner = RecordingRunner();
      final reviews = <CommandApproval>[];
      final gate = SandboxedProcessRunner(
          inner: inner,
          mode: mode,
          commandApprover: (_, review) async {
            reviews.add(review);
            return Approval.no;
          });
      gate.grants.rememberRequest(command(), permissions: {
        ProcessPermission.execution,
        ProcessPermission.network
      });
      expect(
          await gate.run(command(), control: outside), isA<CommandRefused>());
      expect(inner.requests, isEmpty);
      expect(reviews.single.requiredPermissions, {
        ProcessPermission.execution,
        ProcessPermission.network,
        ProcessPermission.unconfined
      });
      expect(reviews.single.missingPermissions, {ProcessPermission.unconfined});
      expect(reviews.single.sandboxReason, 'host executable is hidden');
      expect(reviews.single.reason, contains('host filesystem and network'));
      expect(
          gate.grants.coversRequest(command(),
              permission: ProcessPermission.unconfined),
          false);
    });
  }

  test('outside Always matches exact requests; normal calls remain confined',
      () async {
    final inner = RecordingRunner();
    var reviews = 0;
    final gate = SandboxedProcessRunner(
        inner: inner,
        commandApprover: (_, __) async =>
            ++reviews == 1 ? Approval.always : Approval.no);
    final original = command(env: {'A': '1', 'B': '2'}, stdin: 'input');
    expect(await gate.run(original, control: outside), isA<CommandCompleted>());
    expect(inner.controls.last!.outsideSandboxAllowed, true);
    expect(inner.controls.last!.networkAllowed, true);
    await gate.run(command(env: {'B': '2', 'A': '1'}, stdin: 'input'),
        control: outside);
    expect(reviews, 1);
    for (final changed in [
      command(
          program: '/usr/bin/git', env: original.environment, stdin: 'input'),
      command(args: ['push'], env: original.environment, stdin: 'input'),
      command(cwd: '/other', env: original.environment, stdin: 'input'),
      command(env: {'A': 'changed', 'B': '2'}, stdin: 'input'),
      command(env: original.environment, stdin: 'different'),
      command(env: {}, stdin: 'input'),
      command(stdin: 'input'),
    ]) {
      expect(await gate.run(changed, control: outside), isA<CommandRefused>());
    }
    await gate.run(original);
    expect(inner.controls.last!.outsideSandboxAllowed, false);
    expect(inner.controls.last!.networkAllowed, false);
    expect(reviews, 8);
    expect(inner.requests, hasLength(3));
  });

  test('legacy approvers and patterns cannot grant confinement removal',
      () async {
    for (final approver in <Approver?>[
      null,
      (_, __) async => Approval.always
    ]) {
      final inner = RecordingRunner();
      final gate = SandboxedProcessRunner(inner: inner, approver: approver);
      gate.grants.rememberPattern('git *');
      gate.grants.rememberRequest(command(), permissions: {
        ProcessPermission.execution,
        ProcessPermission.network
      });
      expect(
          await gate.run(command(), control: outside), isA<CommandRefused>());
      expect(inner.requests, isEmpty);
    }
    expect(await const IoProcessRunner().run(command(), control: outside),
        isA<CommandRefused>());
  });

  test('cancelled approval cannot spawn or install a late outside grant',
      () async {
    final inner = RecordingRunner();
    final ready = Completer<void>();
    final answer = Completer<Approval>();
    final cancel = Completer<void>();
    final gate = SandboxedProcessRunner(
        inner: inner,
        commandApprover: (_, __) {
          ready.complete();
          return answer.future;
        });
    final result = gate.run(command(),
        control: ProcessControl(
            outsideSandboxRequested: true,
            sandboxReason: 'hidden program',
            whenCancelled: cancel.future));
    await ready.future;
    cancel.complete();
    expect(await result, isA<CommandRefused>());
    answer.complete(Approval.always);
    await Future<void>.delayed(Duration.zero);
    expect(inner.requests, isEmpty);
    expect(gate.grants.isEmpty, true);
  });

  for (final shell in [false, true]) {
    test(
        '${shell ? 'bash' : 'exec'} validates requests and resets authorization',
        () async {
      final inner = RecordingRunner();
      final jobs = ProcessJobs(inner);
      addTearDown(jobs.close);
      final ProcessToolBase tool =
          shell ? BashTool(runner: jobs) : ExecTool(runner: jobs);
      final input = shell ? {'command': 'echo hello'} : {'program': 'echo'};
      for (final invalid in [
        {'outside_sandbox': 'true'},
        {'outside_sandbox': true},
        {'outside_sandbox': true, 'sandbox_reason': '   '},
      ]) {
        expect((await tool.execute({...input, ...invalid})).isError, true);
      }
      expect(inner.requests, isEmpty);
      final result = await tool.execute({
        ...input, 'outside_sandbox': true, 'sandbox_reason': 'hidden program',
        // Tool input must never supply authorization.
        'outsideSandboxAllowed': true, 'networkAllowed': true,
      },
          control: const ProcessControl(
              outsideSandboxAllowed: true, networkAllowed: true));
      expect(result.isError, false);
      expect(inner.controls.single!.outsideSandboxRequested, true);
      expect(inner.controls.single!.sandboxReason, 'hidden program');
      expect(inner.controls.single!.outsideSandboxAllowed, false);
      expect(inner.controls.single!.networkAllowed, false);
      expect((tool.schema.inputSchema['properties'] as Map).keys,
          containsAll(['outside_sandbox', 'sandbox_reason']));
    });
  }

  for (final backend in [SandboxBackend.bwrap, SandboxBackend.sandboxExec]) {
    test('$backend only bypasses after explicit approval; keeps filtered env',
        () async {
      final inner = RecordingRunner();
      final jail = OsSandboxRunner(
          inner: inner,
          backend: backend,
          plan: const SandboxPlan(
              workspaceRoot: '/project',
              childEnvironment: {'PATH': '/usr/bin:/bin', 'HOME': '/tmp'}));
      expect(
          await jail.run(command(), control: outside), isA<CommandRefused>());
      expect(
          await jail.run(command(),
              control: outside.copyWith(outsideSandboxAllowed: true)),
          isA<CommandRefused>());
      expect(inner.requests, isEmpty);
      final gate = SandboxedProcessRunner(
          inner: jail, commandApprover: (_, __) async => Approval.yes);
      await gate.run(command(env: {'PROVIDER_TOKEN': 'must-not-inherit'}),
          control: outside);
      expect(inner.requests.single.command, 'git');
      expect(inner.requests.single.arguments, ['fetch', 'origin']);
      expect(inner.requests.single.environment,
          {'PATH': '/usr/bin:/bin', 'HOME': '/tmp'});
      expect(inner.controls.single!.outsideSandboxAllowed, true);
      await gate.run(command());
      expect(inner.requests.last.command,
          backend == SandboxBackend.bwrap ? 'bwrap' : 'sandbox-exec');
      expect(inner.controls.last!.outsideSandboxAllowed, false);
    });
  }

  test('explicit startup disable keeps permission gate and clean environment',
      () async {
    final inner = RecordingRunner();
    final jail = OsSandboxRunner(
        inner: inner,
        enabled: false,
        backend: SandboxBackend.bwrap,
        unavailableBehaviour: UnavailableBehaviour.refuse,
        plan: const SandboxPlan(workspaceRoot: '/project'));
    final gate = SandboxedProcessRunner(inner: jail);
    expect(await gate.run(command()), isA<CommandRefused>());
    expect(inner.requests, isEmpty);
    gate.commandApprover = (_, __) async => Approval.yes;
    await gate.run(command());
    expect(inner.requests.single.command, 'git');
    expect(inner.requests.single.environment, jail.plan.childEnvironment);
    expect(jail.describeEnvironment(), contains('--no-sandbox'));
    expect(jail.describeEnvironment(), contains('host filesystem and network'));
  });

  test(
      'Linux names hidden host executable before spawn and allows exact recovery',
      () async {
    final dir = Directory.systemTemp.createTempSync('tina-hidden-executable-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final executable = File('${dir.path}/blender')
      ..writeAsStringSync('fixture');
    final inner = RecordingRunner();
    final jail = OsSandboxRunner(
        inner: inner,
        backend: SandboxBackend.bwrap,
        plan: const SandboxPlan(workspaceRoot: '/project'),
        hostLayout: () => SandboxHostLayout(
            readOnlyDirectories: ['/usr', '/bin'], temporaryDirectories: []));
    final gate = SandboxedProcessRunner(
        inner: jail, commandApprover: (_, __) async => Approval.yes);
    final request = command(program: executable.path, args: ['-b']);
    final result = await gate.run(request);
    expect(result, isA<CommandBlocked>());
    expect((result as CommandBlocked).reason, contains(executable.path));
    expect(result.reason, contains('outside_sandbox: true'));
    expect(result.reason, contains('stat/read success'));
    expect(inner.requests, isEmpty);
    await gate.run(request, control: outside);
    expect(inner.requests.single.command, executable.path);
    expect(inner.requests.single.arguments, ['-b']);
    final link = Link('${dir.path}/alias')..createSync(executable.path);
    final symlinkJail = OsSandboxRunner(
        inner: inner,
        backend: SandboxBackend.bwrap,
        plan: const SandboxPlan(workspaceRoot: '/project'),
        hostLayout: () => SandboxHostLayout(
            readOnlyDirectories: ['/usr'], temporaryDirectories: []));
    final aliasResult = await symlinkJail.run(command(program: link.path));
    expect(aliasResult, isA<CommandBlocked>());
    expect((aliasResult as CommandBlocked).reason, contains(link.path));
    final mountedAlias = OsSandboxRunner(
        inner: inner,
        backend: SandboxBackend.bwrap,
        plan: SandboxPlan(workspaceRoot: link.path),
        hostLayout: () => SandboxHostLayout(
            readOnlyDirectories: ['/usr'], temporaryDirectories: []));
    expect(await mountedAlias.run(command(program: link.path)),
        isA<CommandCompleted>());
    expect(inner.requests.last.command, 'bwrap',
        reason: 'a bind exposes symlink source contents at its destination');
  });

  test('prompt describes actual backend layout and file/process difference',
      () {
    final linux = OsSandboxRunner(
        inner: RecordingRunner(),
        backend: SandboxBackend.bwrap,
        plan: const SandboxPlan(
            workspaceRoot: '/project',
            tinaDir: '/data/.tina',
            writablePaths: ['/extra']),
        hostLayout: () => SandboxHostLayout(
            readOnlyDirectories: ['/usr', '/opt'],
            temporaryDirectories: ['/scratch'],
            resolverTarget: '/run/resolver'));
    final prompt = linux.describeEnvironment();
    expect(prompt, contains('/usr, /opt, /data/.tina, /run/resolver'));
    expect(prompt, contains('/project, /extra, /scratch'));
    expect(prompt, contains('stat/read does not prove'));
    final mac = OsSandboxRunner(
        inner: RecordingRunner(),
        backend: SandboxBackend.sandboxExec,
        plan: const SandboxPlan(workspaceRoot: '/project'));
    expect(mac.describeEnvironment(), contains('can read the host filesystem'));
    expect(mac.describeEnvironment(), contains('Network is isolated'));
  });

  test('ENOENT only diagnoses host paths excluded from Linux mounts', () {
    const file = '/home/user/Blender App/blender';
    for (final stderr in [
      'bwrap: execvp $file: No such file or directory',
      '/bin/sh: line 1: $file: No such file or directory',
      '/bin/sh: 1: $file: not found',
      "cat: '$file': No such file or directory",
    ]) {
      final denial = classifySandboxFailure(
          CommandCompleted(exitCode: 127, stdout: '', stderr: stderr),
          writablePaths: ['/project'],
          mountedPaths: ['/usr', '/project'],
          hostFileExists: (path) => path == file);
      expect(denial, isA<PathHidden>(), reason: stderr);
      expect((denial as PathHidden).hiddenPaths, [file]);
    }
    for (final result in [
      CommandCompleted(
          exitCode: 0,
          stdout: '',
          stderr: 'bwrap: execvp $file: No such file or directory'),
      CommandCompleted(
          exitCode: 127,
          stdout: 'bwrap: execvp $file: No such file or directory',
          stderr: ''),
      const CommandCompleted(
          exitCode: 127,
          stdout: '',
          stderr: 'bwrap: execvp /missing/file: No such file or directory'),
      const CommandCompleted(
          exitCode: 127,
          stdout: '',
          stderr: 'bwrap: execvp /usr/bin/tool: No such file or directory'),
      CommandCompleted(
          exitCode: -9,
          stdout: '',
          stderr: 'bwrap: execvp $file: No such file or directory',
          cancelled: true),
      CommandCompleted(
          exitCode: -9,
          stdout: '',
          stderr: 'bwrap: execvp $file: No such file or directory',
          timedOut: true),
    ]) {
      expect(
          classifySandboxFailure(result,
              writablePaths: ['/project'],
              mountedPaths: ['/usr', '/project'],
              hostFileExists: (path) =>
                  path == file || path == '/usr/bin/tool'),
          isNull);
    }
  });
}
