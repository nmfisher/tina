import 'dart:io';
import 'dart:async';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tools/tina_tools.dart';
import 'package:tina_tui/tina_tui.dart';

class PendingApproval implements ApprovalRequester {
  final ready = Completer<void>();
  final answer = Completer<ApprovalDecision>();
  @override
  Future<ApprovalDecision> request(
      {required String operation,
      required String target,
      required String reason,
      ApprovalKind kind = ApprovalKind.permission,
      Map<String, Object?> details = const {}}) {
    ready.complete();
    return answer.future;
  }
}

void main() {
  test('cancelled late always response creates no file grant or write',
      () async {
    final root = Directory.systemTemp.createTempSync('tina_late_grant_');
    addTearDown(() => root.deleteSync(recursive: true));
    final ws = Directory('${root.path}/project')..createSync();
    final tina = Directory('${root.path}/tina')..createSync();
    final tools =
        ToolsPlugin(workspaceRoot: ws.path, tinaDir: tina, osSandbox: false);
    addTearDown(tools.closeSession);
    final approvals = PendingApproval();
    tools.modePolicy.approvals = approvals;
    final token = CancelToken();
    tools.modePolicy.onInput(TurnContext(token,
        input: const Input('write', id: 't'),
        messages: [],
        promptSections: [],
        pinnedTools: []));
    final target = '${root.path}/outside.txt';
    final write = tools.sandbox.writeFile(target, 'must not write');
    final failed = expectLater(write, throwsA(isA<SandboxViolation>()));
    await approvals.ready.future;
    token.cancel('cancelled');
    approvals.answer.complete(ApprovalDecision.allowAlways);
    await failed;
    expect(tools.sandbox.grants.isEmpty, isTrue);
    expect(File(target).existsSync(), isFalse);
  });

  test(
      'exact file and execution/network grants isolate panels and expire on resume',
      () async {
    final root = Directory.systemTemp.createTempSync('tina_grants_');
    addTearDown(() => root.deleteSync(recursive: true));
    final project = Directory('${root.path}/project')..createSync();
    final outside = Directory('${root.path}/outside')..createSync();
    final target = '${outside.path}/literal*.txt';
    TuiAssembly start({String? resume}) => TuiAssembly.start(
        providerFactory: (_) => ScriptedProvider([scriptedReply('saved')]),
        options: AssemblyOptions(
            configPath: '/nonexistent/tina/config',
            workingDirectory: project.path,
            sessionId: resume));
    final app = start();
    var closed = false;
    addTearDown(() {
      if (!closed) app.close();
    });
    final command = (
      command: '/bin/sh',
      arguments: ['-c', 'printf remembered'],
      workingDirectory: project.path,
      environment: null,
      stdin: null,
      timeout: null,
    );
    var commandAsks = 0;
    app.tools.processRunner.commandApprover = (_, __) async {
      commandAsks++;
      return Approval.always;
    };
    const network = ProcessControl(
        networkRequested: true, networkReason: 'test network grant');
    await app.tools.processRunner.run(command, control: network);
    await app.tools.processRunner.run(command, control: network);
    await app.tools.processRunner.run(command);
    expect(commandAsks, 1);
    expect(
        app.tools.processRunner.grants
            .coversRequest(command, permission: ProcessPermission.network),
        true);
    var asks = 0;
    app.tools.sandbox.approver = (_, __) async {
      asks++;
      return Approval.always;
    };
    await atomicWriteFile(app.tools.sandbox, target, 'first');
    await atomicWriteFile(app.tools.sandbox, target, 'second');
    expect(asks, 1);
    expect(File(target).readAsStringSync(), 'second');
    app.tools.sandbox.approver = (_, __) async {
      asks++;
      return Approval.no;
    };
    for (final sibling in ['other.txt', 'literalXYZ.txt']) {
      await expectLater(
          app.tools.sandbox.writeFile('${outside.path}/$sibling', 'blocked'),
          throwsA(isA<SandboxViolation>()));
      expect(File('${outside.path}/$sibling').existsSync(), isFalse);
    }
    expect(asks, 3);
    final panel = app.newSession(null);
    var panelCommandAsks = 0;
    panel.tools.processRunner.commandApprover = (_, __) async {
      panelCommandAsks++;
      return Approval.no;
    };
    expect(await panel.tools.processRunner.run(command), isA<CommandRefused>());
    expect(await panel.tools.processRunner.run(command, control: network),
        isA<CommandRefused>());
    expect(panelCommandAsks, 2);
    expect(panel.tools.processRunner.grants.isEmpty, true);
    panel.tools.sandbox.approver = (_, __) async => Approval.no;
    await expectLater(panel.tools.sandbox.writeFile(target, 'panel'),
        throwsA(isA<SandboxViolation>()));
    panel.close();
    await app.host.send('save this session');
    final id = app.host.session.id;
    app.close();
    closed = true;
    final resumed = start(resume: id);
    addTearDown(resumed.close);
    var resumeCommandAsks = 0;
    resumed.tools.processRunner.commandApprover = (_, __) async {
      resumeCommandAsks++;
      return Approval.no;
    };
    expect(
        await resumed.tools.processRunner.run(command), isA<CommandRefused>());
    expect(await resumed.tools.processRunner.run(command, control: network),
        isA<CommandRefused>());
    expect(resumeCommandAsks, 2);
    expect(resumed.tools.processRunner.grants.isEmpty, true);
    resumed.tools.sandbox.approver = (_, __) async => Approval.no;
    await expectLater(resumed.tools.sandbox.writeFile(target, 'resumed'),
        throwsA(isA<SandboxViolation>()));
    expect(File(target).readAsStringSync(), 'second');
  });
}
