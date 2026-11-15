import 'dart:io';
import 'dart:async';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_tools/tina_tools.dart';
import 'package:tina/session.dart';
import 'package:tina/src/config_settings_management.dart';

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
  for (final recursive in [false, true]) {
    for (final write in [false, true]) {
      test(
        'saved ${write ? 'read-write' : 'read'} ${recursive ? 'directory' : 'file'} grants persist and revoke',
        () async {
          final root = Directory(
            Directory.systemTemp
                .createTempSync('tina-path-grants-')
                .resolveSymbolicLinksSync(),
          );
          addTearDown(() => root.deleteSync(recursive: true));
          final workspace = Directory('${root.path}/workspace')..createSync();
          final outside = Directory('${root.path}/outside')..createSync();
          final target = File('${outside.path}/literal*.txt')
            ..writeAsStringSync('initial');
          final sibling = File('${outside.path}/sibling')
            ..writeAsStringSync('sibling');
          final config = File('${root.path}/config')
            ..writeAsStringSync('[default]\nmodel = "fixture"\n');
          final original = config.readAsStringSync();
          SessionAssembly start() => SessionAssembly.start(
            providerFactory: (_) => ScriptedProvider([]),
            options: AssemblyOptions(
              configPath: config.path,
              workingDirectory: workspace.path,
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
            asks++;
            final offer = (request.details['directory_accesses'] as List)
                .cast<Map>()
                .singleWhere(
                  (offer) =>
                      offer['path'] == (recursive ? outside.path : target.path),
                );
            channel.respond(
              request.id,
              ApprovalDecision.allow,
              directoryGrants: [
                DirectoryAccessGrant(
                  offer['path'] as String,
                  write ? DirectoryAccess.write : DirectoryAccess.read,
                  DirectoryGrantScope.workspace,
                  recursive: recursive,
                ),
              ],
            );
          });
          addTearDown(sub.cancel);
          app.tools.modePolicy.approvals = approvals;
          if (write) {
            await atomicWriteFile(app.tools.sandbox, target.path, 'approved');
          } else {
            expect(
              await app.tools.sandbox.readFileString(target.path),
              'initial',
            );
          }
          expect(asks, 1);
          expect(
            File('${workspace.path}/.tina/permissions.json').existsSync(),
            true,
          );
          expect(config.readAsStringSync(), original);
          app.close();
          app = start();
          // A separate panel reads the same human-owned manifest.
          final panel = app.newSession(null);
          addTearDown(panel.close);
          expect(
            await panel.tools.sandbox.readFileString(target.path),
            write ? 'approved' : 'initial',
          );
          if (write) {
            await atomicWriteFile(app.tools.sandbox, target.path, 'resumed');
          } else {
            await expectLater(
              app.tools.sandbox.writeFile(target.path, 'blocked'),
              throwsA(isA<SandboxViolation>()),
            );
          }
          if (recursive) {
            expect(
              await panel.tools.sandbox.readFileString(sibling.path),
              'sibling',
            );
          } else {
            await expectLater(
              panel.tools.sandbox.readFileString(sibling.path),
              throwsA(isA<SandboxViolation>()),
            );
          }
          final management = ConfigSettingsManagement(
            scopedSettings: app.settings,
            backend: app.settingsBackend,
            commandApprovals: (app.tools as ToolsPlugin).commandApprovals,
          );
          addTearDown(management.close);
          final saved = management.commandApprovals.singleWhere(
            (g) => g['directory'] == (recursive ? outside.path : target.path),
          );
          management.revokeCommandApproval(saved['id'] as String);
          await expectLater(
            panel.tools.sandbox.readFileString(target.path),
            throwsA(isA<SandboxViolation>()),
          );
          expect(
            management.commandApprovals.any((g) => g['id'] == saved['id']),
            false,
          );
        },
      );
    }
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
}
