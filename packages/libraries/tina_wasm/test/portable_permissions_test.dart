import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_mode/tina_mode.dart';
import 'package:tina_tools/tina_tools.dart' show IoFileSystem, SandboxViolation;
import 'package:tina_wasm/src/portable_tools_plugin.dart';

class Human implements ApprovalRequester {
  final requests = <Map<String, Object?>>[];
  @override
  Future<ApprovalDecision> request({
    required String operation,
    required String target,
    required String reason,
    ApprovalKind kind = ApprovalKind.permission,
    Future<void>? whenCancelled,
    Map<String, Object?> details = const {},
    void Function(String)? onCommandPattern,
    void Function(List<DirectoryAccessGrant>)? onDirectoryGrants,
  }) async {
    requests.add(details);
    // A legacy Always answer must still apply only to the invocation.
    return ApprovalDecision.allowAlways;
  }
}

class Judge extends PermissionClassifier {
  Judge() : super(() => throw StateError('unused provider'));
  final requests = <Map<String, Object?>>[];
  @override
  Future<PermissionJudgment> classify(
    Map<String, Object?> request, {
    Future<void>? whenCancelled,
  }) async {
    requests.add(request);
    return const PermissionJudgment(true);
  }
}

void main() {
  late Directory fixture, workspace;
  setUp(() {
    fixture = Directory.systemTemp.createTempSync('portable-permissions-');
    workspace = Directory('${fixture.path}/workspace')..createSync();
    addTearDown(() => fixture.deleteSync(recursive: true));
  });
  for (final mode in [PermissionMode.approve, PermissionMode.auto]) {
    test(
      '$mode portable workspace writes require one human session grant',
      () async {
        final human = Human(), judge = Judge();
        final plugin = PortableToolsPlugin(
          fileSystem: const IoFileSystem(),
          workspaceRoot: workspace.path,
          mode: mode,
        );
        addTearDown(plugin.modePolicy.closeSession);
        plugin.attachApprovals(human);
        plugin.modePolicy.classifier = judge;
        final source = File('${workspace.path}/source')
          ..writeAsStringSync('read');
        expect(await plugin.sandbox.readFileString(source.path), 'read');
        expect(human.requests, isEmpty);
        await plugin.sandbox.writeFile('${workspace.path}/one', '1');
        await plugin.sandbox.writeFile('${workspace.path}/two', '2');
        expect(human.requests, hasLength(1));
        expect(human.requests.single['workspace_write_grant'], true);
        expect(judge.requests, isEmpty);
        final fresh = PortableToolsPlugin(
          fileSystem: const IoFileSystem(),
          workspaceRoot: workspace.path,
          mode: mode,
        );
        addTearDown(fresh.modePolicy.closeSession);
        await expectLater(
          fresh.sandbox.writeFile('${workspace.path}/three', '3'),
          throwsA(isA<SandboxViolation>()),
        );
      },
    );
  }
  test(
    'portable external access is reviewed per invocation with workspace context',
    () async {
      final human = Human(), judge = Judge();
      final plugin = PortableToolsPlugin(
        fileSystem: const IoFileSystem(),
        workspaceRoot: workspace.path,
      );
      addTearDown(plugin.modePolicy.closeSession);
      plugin.attachApprovals(human);
      plugin.modePolicy.classifier = judge;
      final source = File('${fixture.path}/outside')
        ..writeAsStringSync('external');
      for (var i = 0; i < 2; i++) {
        expect(await plugin.sandbox.readFileString(source.path), 'external');
      }
      expect(human.requests, hasLength(2));
      expect(plugin.sandbox.grants.isEmpty, true);
      plugin.mode = PermissionMode.auto;
      for (var i = 0; i < 2; i++) {
        expect(await plugin.sandbox.readFileString(source.path), 'external');
      }
      expect(judge.requests, hasLength(2));
      expect(
        judge.requests.every((r) => r['workspace'] == workspace.path),
        true,
      );
      expect(human.requests, hasLength(2));
    },
  );
}
