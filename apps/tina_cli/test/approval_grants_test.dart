import 'dart:io';
import 'dart:async';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tools/tina_tools.dart';
import 'package:tina/session.dart';
import 'package:tina/tui.dart';
import 'package:tina_settings/tina_settings.dart';

final class AccessJudge extends PermissionClassifier {
  AccessJudge(this.directory, {this.unavailable = false})
    : super(() => throw StateError('unused'));
  final String directory;
  final bool unavailable;
  @override
  Future<PermissionJudgment> classify(
    Map<String, Object?> request, {
    Future<void>? whenCancelled,
  }) async => unavailable
      ? const PermissionJudgment(null, 'timed out')
      : PermissionJudgment.denied(
          'External reads require review.',
          assessment: PermissionAccessAssessment(
            accesses: [
              PermissionAccess(
                PermissionAccessOperation.read,
                directory,
                PermissionTargetKind.directory,
              ),
            ],
            coverage: PermissionAccessCoverage.partial,
            unresolved: const ['Shell effects are inferred.'],
          ),
        );
}

class PendingApproval implements ApprovalRequester {
  final ready = Completer<void>();
  final answer = Completer<ApprovalDecision>();
  @override
  Future<ApprovalDecision> request(
      {required String operation,
      required String target,
      required String reason,
      ApprovalKind kind = ApprovalKind.permission,
      Map<String, Object?> details = const {},
      void Function(String pattern)? onCommandPattern,
      void Function(List<DirectoryAccessGrant> grants)? onDirectoryGrants}) {
    ready.complete();
    return answer.future;
  }
}

void main() {
  for (final entry in [
    for (final scope in DirectoryGrantScope.values)
      (scope: scope, inferred: true),
    (scope: DirectoryGrantScope.workspace, inferred: false),
  ]) {
    final scope = entry.scope;
    test(
      '${entry.inferred ? "inferred shell" : "verified timeout"} read grant persists only at ${scope.name} scope',
      () async {
        final root = Directory(
          Directory.systemTemp
              .createTempSync('tina-access-grants-')
              .resolveSymbolicLinksSync(),
        );
        addTearDown(() => root.deleteSync(recursive: true));
        final ws = Directory('${root.path}/workspace')..createSync();
        final external = Directory('${root.path}/library')..createSync();
        File('${external.path}/source.txt').writeAsStringSync('needle\n');
        final global = File('${root.path}/config')
          ..writeAsStringSync('''
[default]
model = "scripted"
[plugins.overrides]
"tina/persistence" = false
''');
        final originalGlobal = global.readAsStringSync();
        SessionAssembly start() => SessionAssembly.start(
          providerFactory: (_) => ScriptedProvider([]),
          options: AssemblyOptions(
            configPath: global.path,
            workingDirectory: ws.path,
            osSandbox: false,
          ),
        );
        var app = start();
        addTearDown(() => app.close());
        final channel = StreamApprovalChannel();
        final approvals = ApprovalsPlugin(channel: channel);
        addTearDown(approvals.closeSession);
        addTearDown(channel.closeSession);
        var asks = 0;
        final sub = channel.requests.listen((request) {
          try {
            asks++;
            final accesses = request.details['accesses'] as List;
            expect(
              accesses.single['source'],
              entry.inferred ? 'inferred' : 'verified',
            );
            expect(accesses.single['operation'], 'read');
            expect(
              request.details['access_coverage'],
              entry.inferred ? 'partial' : 'complete',
            );
            final offer =
                (request.details['directory_accesses'] as List).single;
            channel.respond(
              request.id,
              ApprovalDecision.allow,
              directoryGrants: [
                DirectoryAccessGrant(
                  offer['path'] as String,
                  DirectoryAccess.read,
                  scope,
                ),
              ],
            );
          } finally {
            channel.respond(request.id, ApprovalDecision.deny);
          }
        });
        addTearDown(sub.cancel);
        app.tools.mode = PermissionMode.auto;
        app.tools.modePolicy
          ..approvals = approvals
          ..classifier = AccessJudge(
            external.path,
            unavailable: !entry.inferred,
          );
        final result = await app.tools.processRunner.run((
          command: entry.inferred ? '/bin/sh' : '/usr/bin/grep',
          arguments: entry.inferred
              ? [
                  '-c',
                  'grep -rn needle ${external.path}/*.txt | head -30; echo done',
                ]
              : ['-rn', 'needle', external.path],
          workingDirectory: ws.path,
          environment: null,
          stdin: null,
          timeout: null,
        ), control: entry.inferred ? null : const ProcessControl(
          networkRequested: true,
          networkReason: 'Exercise unavailable classifier with a verified reader',
        ));
        expect(result, isA<CommandCompleted>());
        expect(asks, 1);
        expect(app.tools.readDirectories.paths, [external.path]);
        expect(app.tools.writeDirectories.paths, isEmpty);
        expect(app.tools.processRunner.grants.isEmpty, true);
        expect(
          app.settings.read(readOnlyDirectoriesSetting).source,
          SettingScope.values.byName(scope.name),
        );
        final local = File('${ws.path}/.tina/config');
        if (local.existsSync()) {
          expect(local.readAsStringSync(), isNot(contains(external.path)));
        }
        expect(global.readAsStringSync(), originalGlobal);
        final permissions = app.settingsBackend.permissionStore;
        expect(
          permissions.settings(CommandApprovalScope.values.byName(scope.name))[
              readOnlyDirectoriesSetting.id],
          scope == DirectoryGrantScope.session ? isNull : [external.path],
        );
        app.tools.modePolicy.approvals = null;
        app.tools.mode = PermissionMode.ask;
        await expectLater(
          app.tools.sandbox.writeFile('${external.path}/blocked', 'blocked'),
          throwsA(isA<SandboxViolation>()),
        );
        app.close();
        app = start();
        expect(
          app.tools.readDirectories.paths,
          scope == DirectoryGrantScope.session ? isEmpty : [external.path],
        );
        expect(app.tools.writeDirectories.paths, isEmpty);
      },
      skip: Platform.isWindows,
    );
  }
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
    SessionAssembly start({String? resume}) => SessionAssembly.start(
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
