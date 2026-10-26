import 'dart:io';
import 'dart:async';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tools/tina_tools.dart';
import 'package:tina/session.dart';
import 'package:tina/tui.dart';
import 'package:tina_settings/tina_settings.dart';

class FileApprovals implements ApprovalRequester {
  FileApprovals(this.decision);
  ApprovalDecision decision;
  int calls = 0;
  @override
  Future<ApprovalDecision> request({
    required String operation,
    required String target,
    required String reason,
    ApprovalKind kind = ApprovalKind.permission,
    Future<void>? whenCancelled,
    Map<String, Object?> details = const {},
    void Function(String pattern)? onCommandPattern,
    void Function(List<DirectoryAccessGrant> grants)? onDirectoryGrants,
  }) async {
    calls++;
    return decision;
  }
}

class PendingApproval implements ApprovalRequester {
  final ready = Completer<void>();
  final answer = Completer<ApprovalDecision>();
  @override
  Future<ApprovalDecision> request({
    required String operation,
    required String target,
    required String reason,
    ApprovalKind kind = ApprovalKind.permission,
    Future<void>? whenCancelled,
    Map<String, Object?> details = const {},
    void Function(String pattern)? onCommandPattern,
    void Function(List<DirectoryAccessGrant> grants)? onDirectoryGrants,
  }) {
    ready.complete();
    return answer.future;
  }
}

void main() {
  for (final scope in DirectoryGrantScope.values) {
    test('read grant persists only at ${scope.name} scope', () async {
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
          osSandbox: true,
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
          expect(accesses.single['source'], 'verified');
          expect(accesses.single['operation'], 'read');
          expect(request.details['access_coverage'], 'complete');
          final offer = (request.details['directory_accesses'] as List).single;
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
        ..classifier = null;
      final result = await app.tools.processRunner.run(
        (
          command: '/usr/bin/grep',
          arguments: ['-rn', 'needle', external.path],
          workingDirectory: ws.path,
          environment: null,
          stdin: null,
          timeout: null,
        ),
        control: ProcessControl(
          readOnlyRequested: true,
          readDirectories: [external.path],
        ),
      );
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
        permissions.settings(
          CommandApprovalScope.values.byName(scope.name),
        )[readOnlyDirectoriesSetting.id],
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
    }, skip: Platform.isWindows);
  }
  test(
    'cancelled late always response creates no file grant or write',
    () async {
      final root = Directory.systemTemp.createTempSync('tina_late_grant_');
      addTearDown(() => root.deleteSync(recursive: true));
      final ws = Directory('${root.path}/project')..createSync();
      final tina = Directory('${root.path}/tina')..createSync();
      final tools = ToolsPlugin(
        workspaceRoot: ws.path,
        tinaDir: tina,
        osSandbox: false,
      );
      addTearDown(tools.closeSession);
      final approvals = PendingApproval();
      tools.modePolicy.approvals = approvals;
      final token = CancelToken();
      tools.modePolicy.onInput(
        TurnContext(
          token,
          input: const Input('write', id: 't'),
          messages: [],
          promptSections: [],
          pinnedTools: [],
        ),
      );
      final target = '${root.path}/outside.txt';
      final write = tools.sandbox.writeFile(target, 'must not write');
      final failed = expectLater(write, throwsA(isA<SandboxViolation>()));
      await approvals.ready.future;
      token.cancel('cancelled');
      approvals.answer.complete(ApprovalDecision.allowAlways);
      await failed;
      expect(tools.sandbox.grants.isEmpty, isTrue);
      expect(File(target).existsSync(), isFalse);
    },
  );

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
          sessionId: resume,
        ),
      );
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
        readOnlyRequested: false,
        networkRequested: true,
        networkReason: 'test network grant',
      );
      const writable = ProcessControl(readOnlyRequested: false);
      await app.tools.processRunner.run(command, control: network);
      await app.tools.processRunner.run(command, control: network);
      await app.tools.processRunner.run(command, control: writable);
      expect(commandAsks, 1);
      expect(
        app.tools.processRunner.grants.coversRequest(
          command,
          permission: ProcessPermission.network,
        ),
        true,
      );
      final human = FileApprovals(ApprovalDecision.allowAlways);
      app.tools.modePolicy.approvals = human;
      await atomicWriteFile(app.tools.sandbox, target, 'first');
      await atomicWriteFile(app.tools.sandbox, target, 'second');
      expect(human.calls, 1);
      expect(File(target).readAsStringSync(), 'second');
      human.decision = ApprovalDecision.deny;
      for (final sibling in ['other.txt', 'literalXYZ.txt']) {
        await expectLater(
          app.tools.sandbox.writeFile('${outside.path}/$sibling', 'blocked'),
          throwsA(isA<SandboxViolation>()),
        );
        expect(File('${outside.path}/$sibling').existsSync(), isFalse);
      }
      expect(human.calls, 3);
      final panel = app.newSession(null);
      var panelCommandAsks = 0;
      panel.tools.processRunner.commandApprover = (_, __) async {
        panelCommandAsks++;
        return Approval.no;
      };
      expect(
        await panel.tools.processRunner.run(command, control: writable),
        isA<CommandRefused>(),
      );
      expect(
        await panel.tools.processRunner.run(command, control: network),
        isA<CommandRefused>(),
      );
      expect(panelCommandAsks, 2);
      expect(panel.tools.processRunner.grants.isEmpty, true);
      panel.tools.modePolicy.approvals = FileApprovals(ApprovalDecision.deny);
      await expectLater(
        panel.tools.sandbox.writeFile(target, 'panel'),
        throwsA(isA<SandboxViolation>()),
      );
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
        await resumed.tools.processRunner.run(command, control: writable),
        isA<CommandRefused>(),
      );
      expect(
        await resumed.tools.processRunner.run(command, control: network),
        isA<CommandRefused>(),
      );
      expect(resumeCommandAsks, 2);
      expect(resumed.tools.processRunner.grants.isEmpty, true);
      resumed.tools.modePolicy.approvals = FileApprovals(ApprovalDecision.deny);
      await expectLater(
        resumed.tools.sandbox.writeFile(target, 'resumed'),
        throwsA(isA<SandboxViolation>()),
      );
      expect(File(target).readAsStringSync(), 'second');
    },
  );
}
