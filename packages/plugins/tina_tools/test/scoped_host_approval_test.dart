import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_tools/tina_tools.dart';

void main() {
  late Directory root, host, workspace;
  setUp(() {
    root = Directory.systemTemp.createTempSync('tina-scoped-host-');
    host = Directory('${root.path}/home')..createSync();
    workspace = Directory('${root.path}/work')..createSync();
  });
  tearDown(() => root.deleteSync(recursive: true));
  ToolsPlugin plugin(ApprovalRequester approvals, {String? cwd}) {
    final tools = ToolsPlugin(
        workspaceRoot: cwd ?? workspace.path,
        tinaDir: Directory('${cwd ?? workspace.path}/.tina'),
        hostEnvironment: {
          'HOME': host.path,
          'PATH': '/usr/bin:/bin',
          'TMPDIR': root.path
        });
    tools.modePolicy.approvals = approvals;
    addTearDown(tools.closeSession);
    return tools;
  }

  ProcessRequest command([String? cwd]) => (
        command: '/bin/echo',
        arguments: ['hello'],
        workingDirectory: cwd ?? workspace.path,
        environment: null,
        stdin: null,
        timeout: null
      );
  const outside = ProcessControl(
      outsideSandboxRequested: true, sandboxReason: 'host identity required');

  for (final hostCommand in [false, true]) {
    test(
        'reviewed regex reuses ${hostCommand ? 'host' : 'sandboxed'} approval across command values',
        () async {
      final channel = StreamApprovalChannel();
      final service = ApprovalsPlugin(channel: channel);
      addTearDown(service.closeSession);
      var prompts = 0;
      final subscription = channel.requests.listen((request) {
        prompts++;
        channel.respond(
            request.id,
            prompts == 1
                ? ApprovalDecision.allowWorkspace
                : ApprovalDecision.deny,
            commandPattern:
                prompts == 1 ? r'printf hello \| head -n[0-9]+' : null);
      });
      addTearDown(() async {
        channel.closeSession();
        await subscription.cancel();
      });
      final tools = plugin(service);
      ProcessRequest shell(String script) => (
            command: '/bin/sh',
            arguments: ['-c', script],
            workingDirectory: workspace.path,
            environment: null,
            stdin: null,
            timeout: const Duration(seconds: 10),
          );
      final control = hostCommand ? outside : null;
      for (final value in ['2', '20']) {
        final outcome = await tools.processRunner
            .run(shell('printf hello | head -n$value'), control: control);
        expect(outcome, isA<CommandCompleted>());
        expect((outcome as CommandCompleted).stdout, 'hello');
      }
      expect(prompts, 1);
      final restarted = plugin(service);
      expect(
          await restarted.processRunner
              .run(shell('printf hello | head -n3'), control: control),
          isA<CommandCompleted>());
      expect(prompts, 1);
      expect(
          await tools.processRunner.run(
              shell('printf hello | head -n2; echo extra'),
              control: control),
          isA<CommandRefused>());
      expect(prompts, 2);
      if (!hostCommand) {
        expect(
            await tools.processRunner
                .run(shell('printf hello | head -n2'), control: outside),
            isA<CommandRefused>());
        expect(prompts, 3,
            reason: 'regex cannot acquire host or network permission');
      }
    });
  }

  for (final decision in [
    ApprovalDecision.allowAlways,
    ApprovalDecision.allowWorkspace,
    ApprovalDecision.allowGlobal
  ]) {
    test(
        '$decision authorizes first explicit request and reuses the grant without a failure',
        () async {
      final approvals = _Approvals(decision);
      final tools = plugin(approvals);
      for (var i = 0; i < 2; i++) {
        final result =
            await tools.processRunner.run(command(), control: outside);
        expect(result, isA<CommandCompleted>());
        expect((result as CommandCompleted).stdout, 'hello\n');
      }
      expect(approvals.calls, 1);
      expect(approvals.details.single['persistent_command_approval'], true);
      final nextApprovals = _Approvals(ApprovalDecision.deny);
      final restarted = plugin(nextApprovals);
      final next =
          await restarted.processRunner.run(command(), control: outside);
      expect(
          next is CommandCompleted, decision != ApprovalDecision.allowAlways);
      expect(nextApprovals.calls,
          decision == ApprovalDecision.allowAlways ? 1 : 0);
      tools.commandApprovals
          .revoke(tools.commandApprovals.entries.single['id'] as String);
      approvals.decision = ApprovalDecision.deny;
      expect(await tools.processRunner.run(command(), control: outside),
          isA<CommandRefused>());
      expect(approvals.calls, 2);
    });
  }

  test('cancelled late global approval never persists or spawns', () async {
    final approvals = _Approvals(ApprovalDecision.allowGlobal)
      ..pending = Completer<ApprovalDecision>();
    final tools = plugin(approvals);
    final cancelled = Completer<void>();
    final result = tools.processRunner.run(command(),
        control: ProcessControl(
            outsideSandboxRequested: true,
            sandboxReason: 'fixture',
            whenCancelled: cancelled.future));
    await approvals.ready.future;
    cancelled.complete();
    expect(await result, isA<CommandRefused>());
    approvals.pending!.complete(ApprovalDecision.allowGlobal);
    await Future<void>.delayed(Duration.zero);
    expect(tools.commandApprovals.entries, isEmpty);
  });

  test('ordinary approvals cannot persist outside permission', () async {
    final approvals = _Approvals(ApprovalDecision.allowGlobal);
    final tools = plugin(approvals);
    expect(await tools.processRunner.run(command()), isA<CommandRefused>());
    expect(tools.commandApprovals.entries, isEmpty);
  });

  test('host executable is pinned before approval, including symlink aliases',
      () async {
    final alias = Link('${workspace.path}/command')..createSync('/bin/echo');
    final approvals = _Approvals(ApprovalDecision.allowWorkspace)
      ..pending = Completer<ApprovalDecision>();
    final tools = plugin(approvals);
    final original = command();
    final request = (
      command: alias.path,
      arguments: original.arguments,
      workingDirectory: original.workingDirectory,
      environment: original.environment,
      stdin: original.stdin,
      timeout: original.timeout,
    );
    final result = tools.processRunner.run(request, control: outside);
    await approvals.ready.future;
    alias.updateSync('/usr/bin/false');
    approvals.pending!.complete(ApprovalDecision.allowWorkspace);
    final completed = await result as CommandCompleted;
    expect(completed.exitCode, 0);
    expect(completed.stdout, 'hello\n');
    approvals
      ..pending = null
      ..decision = ApprovalDecision.deny;
    expect(await tools.processRunner.run(request, control: outside),
        isA<CommandRefused>());
    expect(approvals.calls, 2,
        reason: 'the changed alias does not inherit the earlier grant');
  });

  test('host environment is reviewed and remembered as actually executed',
      () async {
    final environment = {
      'HOME': host.path,
      'PATH': '/usr/bin:/bin',
      'TMPDIR': root.path,
      'LANG': 'C',
      'PROVIDER_TOKEN': 'do-not-forward',
    };
    final approvals = _Approvals(ApprovalDecision.allowWorkspace)
      ..pending = Completer<ApprovalDecision>();
    final tools = ToolsPlugin(
        workspaceRoot: workspace.path,
        tinaDir: Directory('${workspace.path}/.tina'),
        hostEnvironment: environment);
    tools.modePolicy.approvals = approvals;
    addTearDown(tools.closeSession);
    final request = (
      command: '/usr/bin/env',
      arguments: <String>[],
      workingDirectory: workspace.path,
      environment: null,
      stdin: null,
      timeout: const Duration(seconds: 5),
    );
    final pending = tools.processRunner.run(request, control: outside);
    await approvals.ready.future;
    environment['LANG'] = 'changed-after-approval';
    approvals.pending!.complete(ApprovalDecision.allowWorkspace);
    final result = await pending as CommandCompleted;
    expect(result.stdout, contains('LANG=C\n'));
    expect(result.stdout, isNot(contains('do-not-forward')));
    approvals
      ..pending = null
      ..decision = ApprovalDecision.deny;
    expect(await tools.processRunner.run(request, control: outside),
        isA<CommandRefused>());
    expect(approvals.calls, 2,
        reason: 'a changed effective environment requires a new approval');
  });

  test(
      'partial failure offers a named grant and reruns only after explicit approval',
      () async {
    final runner = _PartialRunner('${root.path}/external/output');
    final gate = SandboxedProcessRunner(
        inner: runner,
        plan: SandboxPlan(workspaceRoot: workspace.path, realHome: host.path),
        commandApprover: (_, __) async => Approval.yes);
    var offers = 0;
    gate.directoryApprover = (request, access, retry, active) async {
      offers++;
      expect(retry, true);
      expect(access.path, '${root.path}/external/output');
      expect(access.write, true);
      expect(runner.calls, 1);
      return true;
    };
    expect(await gate.run(command()), isA<CommandCompleted>());
    expect(runner.calls, 2);
    expect(offers, 1);
  });

  test('credential denial never gets an ordinary directory offer', () async {
    final runner = _PartialRunner('${host.path}/.ssh/key');
    final gate = SandboxedProcessRunner(
        inner: runner,
        plan: SandboxPlan(workspaceRoot: workspace.path, realHome: host.path),
        commandApprover: (_, __) async => Approval.yes);
    gate.directoryApprover =
        (_, __, ___, ____) async => fail('credential grant offered');
    expect(await gate.run(command()), isA<CommandBlocked>());
    expect(runner.calls, 1);
  });
}

final class _Approvals implements ApprovalRequester {
  _Approvals(this.decision);
  ApprovalDecision decision;
  int calls = 0;
  final details = <Map<String, Object?>>[];
  Completer<ApprovalDecision>? pending;
  final ready = Completer<void>();
  @override
  Future<ApprovalDecision> request(
      {required String operation,
      required String target,
      required String reason,
      ApprovalKind kind = ApprovalKind.permission,
      Map<String, Object?> details = const {},
      void Function(String pattern)? onCommandPattern}) async {
    calls++;
    this.details.add(details);
    if (!ready.isCompleted) ready.complete();
    return pending == null ? decision : pending!.future;
  }
}

class _PartialRunner implements ProcessRunner {
  _PartialRunner(this.path);
  final String path;
  int calls = 0;
  @override
  Future<RunOutcome> run(ProcessRequest request,
          {ProcessControl? control}) async =>
      ++calls == 1
          ? CommandBlocked('fixture denial after partial work',
              accessRequests: [SandboxAccessRequest(path, write: true)])
          : const CommandCompleted(exitCode: 0, stdout: '', stderr: '');
}
