import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_tools/tina_tools.dart';

const network = ProcessControl(
    networkRequested: true, networkReason: 'fetch project dependencies');

ProcessRequest command({
  String program = 'git',
  List<String> args = const ['fetch', 'origin'],
  String cwd = '/project',
  Map<String, String>? env,
  String? stdin,
}) =>
    (
      command: program,
      arguments: args,
      workingDirectory: cwd,
      environment: env,
      stdin: stdin,
      timeout: null,
    );

class RecordingRunner implements ProcessRunner {
  final requests = <ProcessRequest>[];
  final controls = <ProcessControl?>[];
  @override
  Future<RunOutcome> run(ProcessRequest request,
      {ProcessControl? control}) async {
    requests.add(request);
    controls.add(control);
    control?.onStarted?.call();
    control?.onOutput?.call('done', isError: false);
    return const CommandCompleted(exitCode: 0, stdout: 'done', stderr: '');
  }
}

void main() {
  for (final mode in PermissionMode.values) {
    test('$mode reviews execution and network together before spawning',
        () async {
      final inner = RecordingRunner();
      final reviews = <CommandApproval>[];
      final gate = SandboxedProcessRunner(
          inner: inner,
          mode: mode,
          commandApprover: (_, review) async {
            expect(inner.requests, isEmpty);
            reviews.add(review);
            return Approval.yes;
          });
      expect(
          await gate.run(command(), control: network), isA<CommandCompleted>());
      expect(reviews, hasLength(1));
      expect(reviews.single.requiredPermissions,
          {ProcessPermission.execution, ProcessPermission.network});
      expect(reviews.single.missingPermissions,
          reviews.single.requiredPermissions);
      expect(reviews.single.networkReason, 'fetch project dependencies');
      expect(inner.controls.single!.networkAllowed, true);
      expect(gate.grants.isEmpty, true);
    });
  }

  test('execution Always requires a new network approval, then remembers both',
      () async {
    final inner = RecordingRunner();
    final reviews = <CommandApproval>[];
    final gate = SandboxedProcessRunner(
        inner: inner,
        commandApprover: (_, review) async {
          reviews.add(review);
          return Approval.always;
        });
    final request = command();
    await gate.run(request);
    expect(gate.grants.coversRequest(request), true);
    expect(
        gate.grants
            .coversRequest(request, permission: ProcessPermission.network),
        false);
    expect(inner.controls.last!.networkAllowed, false);
    await gate.run(request, control: network);
    expect(reviews, hasLength(2));
    expect(reviews.last.requiredPermissions,
        {ProcessPermission.execution, ProcessPermission.network});
    expect(reviews.last.missingPermissions, {ProcessPermission.network});
    expect(reviews.last.reason, contains('allow network access'));
    expect(
        gate.grants
            .coversRequest(request, permission: ProcessPermission.network),
        true);
    await gate.run(request, control: network);
    expect(reviews, hasLength(2));
    expect(inner.controls.last!.networkAllowed, true);
    await gate.run(request);
    expect(reviews, hasLength(2));
    expect(inner.controls.last!.networkAllowed, false,
        reason: 'a remembered network grant never opens an offline invocation');
    expect(gate.grants.length, 1);
  });

  test('Allow once and Deny never create network or execution grants',
      () async {
    final inner = RecordingRunner();
    var asks = 0;
    final gate = SandboxedProcessRunner(
        inner: inner,
        commandApprover: (_, review) async {
          asks++;
          return asks == 1 ? Approval.yes : Approval.no;
        });
    expect(
        await gate.run(command(), control: network), isA<CommandCompleted>());
    expect(await gate.run(command(), control: network), isA<CommandRefused>());
    expect(asks, 2);
    expect(inner.requests, hasLength(1));
    expect(gate.grants.isEmpty, true);
  });

  test('network denial preserves an existing execution grant', () async {
    final inner = RecordingRunner();
    final gate = SandboxedProcessRunner(
        inner: inner, commandApprover: (_, review) async => Approval.no);
    gate.grants.rememberRequest(command());
    expect(await gate.run(command(), control: network), isA<CommandRefused>());
    expect(inner.requests, isEmpty);
    expect(await gate.run(command()), isA<CommandCompleted>());
    expect(inner.controls.single!.networkAllowed, false);
    expect(
        gate.grants
            .coversRequest(command(), permission: ProcessPermission.network),
        false);
  });

  test(
      'Always with network matches exact program, argv, cwd, environment and stdin',
      () async {
    final inner = RecordingRunner();
    var asks = 0;
    final gate = SandboxedProcessRunner(
        inner: inner,
        commandApprover: (_, review) async {
          asks++;
          return asks == 1 ? Approval.always : Approval.no;
        });
    final original = command(env: {'A': '1', 'B': '2'}, stdin: 'input');
    await gate.run(original, control: network);
    await gate.run(command(env: {'B': '2', 'A': '1'}, stdin: 'input'),
        control: network);
    expect(asks, 1, reason: 'environment insertion order is immaterial');
    for (final changed in [
      command(
          program: '/usr/bin/git', env: original.environment, stdin: 'input'),
      command(
          args: ['push', 'origin'], env: original.environment, stdin: 'input'),
      command(cwd: '/other', env: original.environment, stdin: 'input'),
      command(env: {'A': 'changed', 'B': '2'}, stdin: 'input'),
      command(env: original.environment, stdin: 'different'),
      command(env: {}, stdin: 'input'),
      command(stdin: 'input'),
    ]) {
      expect(await gate.run(changed, control: network), isA<CommandRefused>());
    }
    expect(asks, 8);
    expect(inner.requests, hasLength(2));
    expect(gate.grants.length, 1);
  });

  test('inherited and empty environment never share network grants', () async {
    final grants = CommandGrants()
      ..rememberRequest(command(), permissions: {
        ProcessPermission.execution,
        ProcessPermission.network
      });
    expect(
        grants.coversRequest(command(env: {}),
            permission: ProcessPermission.network),
        false);
  });

  test('explicit broad execution patterns cannot grant network access',
      () async {
    final inner = RecordingRunner();
    final grants = CommandGrants()..rememberPattern('git *');
    var asks = 0;
    final gate = SandboxedProcessRunner(
        inner: inner,
        grants: grants,
        commandApprover: (_, review) async {
          asks++;
          expect(review.missingPermissions, {ProcessPermission.network});
          return Approval.no;
        });
    await gate.run(command());
    expect(asks, 0);
    expect(await gate.run(command(), control: network), isA<CommandRefused>());
    expect(asks, 1);
    expect(inner.requests, hasLength(1));
  });

  test('network fails closed with no approver or a filesystem-only approver',
      () async {
    for (final fileApprover in <Approver?>[
      null,
      (_, __) async => Approval.always
    ]) {
      final inner = RecordingRunner();
      final gate = SandboxedProcessRunner(inner: inner, approver: fileApprover);
      expect(
          await gate.run(command(), control: network), isA<CommandRefused>());
      expect(inner.requests, isEmpty);
      expect(gate.grants.isEmpty, true);
    }
    expect(await const IoProcessRunner().run(command(), control: network),
        isA<CommandRefused>());
  });

  test(
      'cancellation wins over a late Always answer without spawning or granting',
      () async {
    final inner = RecordingRunner();
    final ready = Completer<void>();
    final answer = Completer<Approval>();
    final cancelled = Completer<void>();
    final gate = SandboxedProcessRunner(
        inner: inner,
        commandApprover: (_, review) {
          ready.complete();
          return answer.future;
        });
    final result = gate.run(command(),
        control: ProcessControl(
            networkRequested: true,
            networkReason: 'fetch',
            whenCancelled: cancelled.future));
    await ready.future;
    cancelled.complete();
    expect(await result, isA<CommandRefused>());
    answer.complete(Approval.always);
    await Future<void>.delayed(Duration.zero);
    expect(inner.requests, isEmpty);
    expect(gate.grants.isEmpty, true);
  });

  test(
      'a pending approval cannot mutate the reviewed command or grant identity',
      () async {
    final args = ['fetch', 'origin'];
    final env = {'A': 'original'};
    final inner = RecordingRunner();
    final ready = Completer<void>();
    final answer = Completer<Approval>();
    final gate = SandboxedProcessRunner(
        inner: inner,
        commandApprover: (request, review) {
          ready.complete();
          return answer.future;
        });
    final result = gate.run(command(args: args, env: env), control: network);
    await ready.future;
    args[0] = 'push';
    env['A'] = 'changed';
    answer.complete(Approval.always);
    await result;
    expect(inner.requests.single.arguments, ['fetch', 'origin']);
    expect(inner.requests.single.environment, {'A': 'original'});
    expect(
        gate.grants.coversRequest(command(env: {'A': 'original'}),
            permission: ProcessPermission.network),
        true);
    expect(
        gate.grants.coversRequest(command(args: args, env: env),
            permission: ProcessPermission.network),
        false);
  });
}
