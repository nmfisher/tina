import 'dart:async';
import 'dart:io';
import 'package:test/test.dart';
import 'package:tina/session.dart';
import 'package:tina/src/snapshot_catalog.dart';
import 'package:tina_approvals/tina_approvals.dart';
import 'package:tina_chat/tina_chat.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_persistence/tina_persistence.dart';
import 'package:tina_mcp/tina_mcp.dart';
import 'turn_rendering_test.dart' show ControlledProvider, waitFor;

void main() {
  test(
    'late attachment captures live preview then reconciles committed output',
    () async {
      final root = Directory.systemTemp.createTempSync('attachment-preview-');
      addTearDown(() => root.deleteSync(recursive: true));
      final provider = ControlledProvider();
      final assembly = SessionAssembly.start(
        providerFactory: (_) => provider,
        options: AssemblyOptions(
          configPath: '${root.path}/config',
          workingDirectory: root.path,
          plugins: ['tina/chat-tui', 'tina/persistence'],
        ),
      );
      addTearDown(assembly.shutdown);
      final connection = assembly.host.connect();
      addTearDown(connection.close);
      final turn = connection.submit('hello');
      await waitFor(() => provider.requests.isNotEmpty);
      provider.requests.single.add(const TextDelta('partial'));
      final chat = assembly.host.plugins
          .whereType<ChatPlugin>()
          .single
          .observation;
      await waitFor(() => (chat.events.snapshot['preview'] as List).isNotEmpty);
      final first = connection.attach(), second = connection.attach();
      final preview =
          (first.initial.features['tina/chat-tui'] as Map)['preview'] as List;
      expect(preview.single, containsPair('text', 'partial'));
      expect(second.initial.throughSeq, first.initial.throughSeq);
      first.close();
      provider.requests.single.add(const TextDelta(' answer'));
      provider.requests.single.add(
        const MessageComplete(
          content: [TextBlock('partial answer')],
          stopReason: 'end_turn',
        ),
      );
      await provider.requests.single.close();
      await turn;
      await Future<void>.delayed(Duration.zero);
      final completed = (await second.next())!.snapshot;
      expect((completed.features['tina/chat-tui'] as Map)['preview'], isEmpty);
      expect(completed.status.running, isFalse);
      expect(preview.single, containsPair('text', 'partial'));
      final history = second.history(snapshot: completed).entries;
      final assistant = history
          .where((e) => e['type'] == 'message_appended')
          .where((e) => (e['message'] as Map)['role'] == 'assistant');
      expect(assistant, hasLength(1));
      final store = SessionStore.open(defaultSessionStorePath(root.path));
      try {
        expect(store.checkGaps(assembly.host.session.id), isEmpty);
        expect(
          store.readEntries(assembly.host.session.id).last.seq,
          completed.throughSeq,
        );
      } finally {
        store.close();
      }
    },
  );

  test(
    'snapshot observation alone never becomes an interactive approver',
    () async {
      final channel = AttachmentApprovalChannel();
      final approvals = ApprovalsPlugin(channel: channel);
      final host = Host.start(
        HostConfig(
          workingDirectory: '.',
          plugins: [approvals, channel],
          providerFactory: (_) => ScriptedProvider([]),
          snapshotFeatureFor: snapshotFeatureFor,
        ),
      );
      addTearDown(host.shutdown);
      final connection = host.connect();
      addTearDown(connection.close);
      connection.attach();
      expect(
        await approvals.request(
          operation: 'read',
          target: '/private',
          reason: 'test',
        ),
        ApprovalDecision.deny,
      );
    },
  );

  test(
    'pending external approvals are visible without acquiring response authority',
    () async {
      final channel = StreamApprovalChannel(id: 'test/external');
      final delivered = Completer<ApprovalRequest>();
      final subscription = channel.requests.listen(delivered.complete);
      addTearDown(subscription.cancel);
      final approvals = ApprovalsPlugin(channel: channel);
      final host = Host.start(
        HostConfig(
          workingDirectory: '.',
          plugins: [approvals, channel],
          providerFactory: (_) => ScriptedProvider([]),
          snapshotFeatureFor: snapshotFeatureFor,
        ),
      );
      addTearDown(host.shutdown);
      final result = approvals.request(
        operation: 'write',
        target: '/file',
        reason: 'test',
        details: {
          'tool': {
            'name': 'write',
            'input': {'path': '/file'},
          },
        },
      );
      final request = await delivered.future;
      final connection = host.connect();
      addTearDown(connection.close);
      final first = connection.attach();
      final pending =
          (first.initial.features[approvals.id] as Map)['pending'] as List;
      expect((pending.single as Map)['id'], request.id);
      first.close();
      final replacement = connection.attach();
      expect(channel.respond(request.id, ApprovalDecision.allow), isTrue);
      expect(await result, ApprovalDecision.allow);
      final update = (await replacement.next())!.snapshot;
      expect((update.features[approvals.id] as Map)['pending'], isEmpty);
      expect(pending, hasLength(1));
    },
  );

  test(
    'MCP attachment data excludes arguments, URLs, headers and environment secrets',
    () {
      final root = Directory.systemTemp.createTempSync('attachment-mcp-');
      addTearDown(() => root.deleteSync(recursive: true));
      File('${root.path}/config').writeAsStringSync('''
[default]
model = "scripted"
[mcp.servers.private]
url = "https://example.test/mcp?token=hidden"
enabled = false
[mcp.servers.private.headers]
Authorization = "Bearer hidden"
''');
      final assembly = SessionAssembly.start(
        providerFactory: (_) => ScriptedProvider([]),
        options: AssemblyOptions(
          configPath: '${root.path}/config',
          workingDirectory: root.path,
          plugins: ['tina/mcp'],
        ),
      );
      addTearDown(assembly.close);
      final connection = assembly.host.connect();
      addTearDown(connection.close);
      final value = connection.attach().initial.features['tina/mcp'] as Map;
      expect(value.toString(), isNot(contains('hidden')));
      expect(value.toString(), isNot(contains('Authorization')));
      expect(value['servers'], [
        {'name': 'private', 'enabled': false, 'transport': 'http'},
      ]);
      expect(assembly.host.plugins.whereType<McpPlugin>(), hasLength(1));
    },
  );
}
