import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina_engine/tina_engine.dart';

import '../helpers/fake_host_interface.dart';
import '../helpers/fake_provider.dart';

class _WriteTool extends Tool {
  final File file;
  int executions = 0;
  _WriteTool(this.file);
  @override
  ToolSchema get schema => const ToolSchema(
    name: 'write_probe',
    description: 'write a marker',
    inputSchema: {'type': 'object'},
  );
  @override
  Future<ToolResult> execute(
    Map<String, dynamic> input, {
    Future<void>? cancelSignal,
    ToolOutputCallback? onOutput,
  }) async {
    executions++;
    await file.writeAsString('effect $executions');
    return ToolResult('saved effect $executions');
  }
}

void main() {
  for (final shutdown in [false, true]) {
    test(
      'tool progress survives ${shutdown ? 'shutdown' : 'cancel'} during approval',
      () async {
        final dir = await Directory.systemTemp.createTemp('turn-persistence-');
        addTearDown(() => dir.delete(recursive: true));
        final store = JsonlSessionStore(Directory('${dir.path}/sessions'));
        final sid = await store.createSession(
          providerId: 'fake',
          cwd: dir.path,
        );
        final cid = await store.createConversation(sid);
        final recorder = SessionRecorder(store, sid, cid, providerId: 'fake')
          ..attach(sid, cid);
        final host = FakeHostInterface();
        final tool = _WriteTool(File('${dir.path}/effect'));
        final provider = FakeProvider([
          [
            MessageComplete(
              content: [
                for (var i = 0; i < 3; i++)
                  ToolUseBlock(id: 'call$i', name: 'write_probe', input: {}),
              ],
              stopReason: 'tool_use',
            ),
          ],
        ]);
        final thirdApproval = Completer<void>();
        final abandonedApproval = Completer<PermissionResponse>();
        var approvals = 0;
        final policy = PermissionPolicy();
        final conversation = Conversation(
          id: cid,
          label: 'test',
          provider: provider,
          host: host,
          policy: policy,
          recorder: recorder,
          agent: Agent(
            provider: provider,
            tools: ToolRegistry([tool]),
            sink: host,
            policy: policy,
            system: '',
            asker: (prompt) async {
              approvals++;
              if (approvals < 3) return PermissionResponse.allowOnce;
              thirdApproval.complete();
              // An uncooperative/custom UI must not strand shutdown.
              return abandonedApproval.future;
            },
          ),
        );
        final turns = TurnExecutor(findConversation: (_) => conversation);
        turns.submit(cid, 'perform three writes');
        await thirdApproval.future.timeout(const Duration(seconds: 3));

        // Read using a fresh store WHILE the turn is blocked: no final flush,
        // graceful shutdown, or in-memory fake can hide lost incremental writes.
        final freshStore = JsonlSessionStore(store.root);
        final checkpoint = await freshStore.loadConversation(sid, cid);
        final results = checkpoint
            .expand((m) => m.content)
            .whereType<ToolResultBlock>()
            .toList();
        expect(results.map((r) => r.content), [
          'saved effect 1',
          'saved effect 2',
        ]);
        expect(tool.executions, 2);
        expect(await tool.file.readAsString(), 'effect 2');
        expect(
          checkpoint.where(
            (m) => m.role == Role.user && m.content.any((b) => b is TextBlock),
          ),
          hasLength(1),
        );

        // A hard-kill restore with a missing result is safe to send again and
        // does not claim the unfinished call never executed.
        expect(recoverInterruptedToolCalls(checkpoint), isTrue);
        final unknown = checkpoint.last.content.last as ToolResultBlock;
        expect(unknown.toolUseId, 'call2');
        expect(unknown.content, contains('status is unknown'));
        expect(recoverInterruptedToolCalls(checkpoint), isFalse);

        if (shutdown) {
          await turns.shutdown().timeout(const Duration(seconds: 3));
        } else {
          turns.cancel(cid);
          await turns.whenIdle(cid).timeout(const Duration(seconds: 3));
        }
        final restored = await freshStore.loadConversation(sid, cid);
        expect(
          restored.expand((m) => m.content).whereType<ToolResultBlock>(),
          hasLength(3),
        );
        expect(restored.last.content.single.toJson()['text'], '[cancelled]');
        expect(tool.executions, 2);
        // A late approval cannot execute, remember a grant, or affect a new turn.
        abandonedApproval.complete(PermissionResponse.allowAlways);
        await Future<void>.delayed(Duration.zero);
        expect(policy.sessionRules, isEmpty);
        expect(tool.executions, 2);
        expect(
          conversation.history.map((m) => m.toJson()),
          restored.map((m) => m.toJson()),
        );
      },
    );
  }
}
