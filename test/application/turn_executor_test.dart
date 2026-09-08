import 'dart:async';
import 'package:test/test.dart';
import 'package:tina/application/turn_executor.dart';
import 'package:tina/conversation.dart';
import 'package:tina/pipeline/workflow_supervisor.dart';
import 'package:tina_engine/tina_engine.dart';
import '../helpers/fake_host_interface.dart';
import '../helpers/memory_session_store.dart';

class _Provider extends LlmProvider {
  _Provider() : super('controlled');
  final started = <Completer<void>>[
    for (var i = 0; i < 5; i++) Completer<void>(),
  ];
  final streams = <StreamController<StreamEvent>>[];
  @override
  Stream<StreamEvent> send({
    required String system,
    required List<Message> messages,
    required List<ToolSchema> tools,
  }) {
    final stream = StreamController<StreamEvent>();
    streams.add(stream);
    started[streams.length - 1].complete();
    return stream.stream;
  }

  void finish(int index) {
    streams[index].add(
      const MessageComplete(
        content: [TextBlock('done')],
        stopReason: 'end_turn',
      ),
    );
    unawaited(streams[index].close());
  }
}

class _Store extends MemorySessionStore {
  final replacing = Completer<void>();
  final releaseReplace = Completer<void>();
  bool gateReplace = false;
  bool failAppend = false;
  @override
  Future<void> append(
    String sessionId,
    String conversationId,
    Message message,
  ) async {
    if (failAppend) throw StateError('disk');
    return super.append(sessionId, conversationId, message);
  }

  @override
  Future<void> replace(
    String sessionId,
    String conversationId,
    List<Message> messages,
  ) async {
    if (gateReplace) {
      replacing.complete();
      await releaseReplace.future;
      gateReplace = false;
    }
    return super.replace(sessionId, conversationId, messages);
  }
}

void main() {
  late _Provider provider;
  late _Store store;
  late Conversation conversation;
  late TurnExecutor executor;
  late FakeHostInterface host;
  setUp(() async {
    provider = _Provider();
    store = _Store();
    host = FakeHostInterface();
    final sid = await store.createSession(providerId: 'test');
    final cid = await store.createConversation(sid);
    final recorder = SessionRecorder(store, sid, cid, providerId: 'test')
      ..attach(sid, cid);
    final agent = Agent(
      provider: provider,
      tools: ToolRegistry(const []),
      sink: host,
      policy: PermissionPolicy(),
      asker: host.askPermission,
      system: '',
    );
    conversation = Conversation(
      id: cid,
      label: 'test',
      agent: agent,
      provider: provider,
      host: host,
      policy: PermissionPolicy(),
      recorder: recorder,
    );
    executor = TurnExecutor(
      findConversation: (id) => id == cid ? conversation : null,
    );
  });
  tearDown(() async {
    await executor.shutdown();
    await host.dispose();
  });
  test('session-owned closure is visible to admission and state', () async {
    conversation.beginClose();
    expect(executor.state(conversation.id), TurnState.closed);
    expect(executor.submit(conversation.id, 'late'), TurnSubmission.rejected);
    expect(provider.streams, isEmpty);
  });
  test(
    'cancellation acknowledgement holds admission through recorder rollback',
    () async {
      final id = conversation.id;
      expect(executor.submit(id, 'first'), TurnSubmission.started);
      await provider.started[0].future;
      store.gateReplace = true;
      expect(executor.cancel(id), isTrue);
      await store.replacing.future;
      expect(executor.state(id), TurnState.cancelling);
      expect(conversation.isRunning, isTrue);
      expect(executor.submit(id, 'second'), TurnSubmission.queued);
      expect(provider.streams.length, 1);
      store.releaseReplace.complete();
      await provider.started[1].future;
      provider.finish(1);
      await executor.whenIdle(id);
      expect(
        conversation.history.first.content.whereType<TextBlock>().single.text,
        'second',
      );
      expect(executor.state(id), TurnState.idle);
      expect(host.activitySignals.last, isFalse);
    },
  );
  test(
    'recorded user precedes provider; assistant follows completion',
    () async {
      executor.submit(conversation.id, 'hello');
      await provider.started[0].future;
      final rec = conversation.recorder!;
      expect(
        (await store.loadConversation(
          rec.sessionId,
          rec.conversationId,
        )).map((m) => m.role),
        [Role.user],
      );
      provider.finish(0);
      await executor.whenIdle(conversation.id);
      expect(
        (await store.loadConversation(
          rec.sessionId,
          rec.conversationId,
        )).map((m) => m.role),
        [Role.user, Role.assistant],
      );
    },
  );
  test('recorder failure does not strand a completed turn', () async {
    store.failAppend = true;
    executor.submit(conversation.id, 'hello');
    await provider.started[0].future;
    provider.finish(0);
    await executor.whenIdle(conversation.id);
    expect(executor.state(conversation.id), TurnState.idle);
    expect(host.activitySignals.last, isFalse);
  });
  test(
    'closing during rollback rejects submissions and prevents queue draining',
    () async {
      executor.submit(conversation.id, 'first');
      await provider.started[0].future;
      executor.submit(conversation.id, 'queued');
      store.gateReplace = true;
      final closed = executor.close(conversation.id);
      await store.replacing.future;
      expect(executor.submit(conversation.id, 'late'), TurnSubmission.rejected);
      store.releaseReplace.complete();
      await closed;
      expect(provider.streams.length, 1);
      expect(executor.state(conversation.id), TurnState.closed);
    },
  );
  test(
    'shutdown cancels and waits, retains already persisted prompt for resume',
    () async {
      executor.submit(conversation.id, 'remember');
      await provider.started[0].future;
      await executor.shutdown();
      expect(executor.submit(conversation.id, 'late'), TurnSubmission.rejected);
      final rec = conversation.recorder!;
      expect(
        (await store.loadConversation(
          rec.sessionId,
          rec.conversationId,
        )).first.role,
        Role.user,
      );
    },
  );
  test(
    'shutdown cancels compaction without changing existing history',
    () async {
      executor.autoCompactThreshold = 1;
      executor = TurnExecutor(
        findConversation: (_) => conversation,
        autoCompactThreshold: 1,
        autoCompactPreserveRecent: 0,
      );
      conversation.history.add(
        const Message(role: Role.user, content: [TextBlock('old history')]),
      );
      executor.submit(conversation.id, 'new');
      await provider.started[0].future;
      await executor.shutdown();
      expect(
        conversation.history.single.content.whereType<TextBlock>().single.text,
        'old history',
      );
    },
  );
  test(
    'workflow completions use admission and cannot reopen a closed conversation',
    () async {
      executor.submit(conversation.id, 'first');
      await provider.started[0].future;
      final result = WorkflowRun(
        id: 'run',
        workflowName: 'workflow',
        conversationId: conversation.id,
        goal: null,
        input: null,
        cancel: Completer<void>(),
      )..status = WorkflowRunStatus.completed;
      executor.injectWorkflowResult(result);
      expect(conversation.messageQueue.length, 1);
      provider.finish(0);
      await provider.started[1].future;
      expect(
        conversation.history
            .where((m) => m.role == Role.user)
            .last
            .content
            .whereType<TextBlock>()
            .single
            .text,
        contains('Workflow "workflow" (run run) finished successfully.'),
      );
      provider.finish(1);
      await executor.whenIdle(conversation.id);
      await executor.close(conversation.id);
      executor.injectWorkflowResult(result);
      expect(provider.streams.length, 2);
    },
  );
  test(
    'tool interruption is distinct and inert without a queued message',
    () async {
      executor.submit(conversation.id, 'first');
      await provider.started[0].future;
      expect(executor.interruptTools(conversation.id), isFalse);
      executor.submit(conversation.id, 'second');
      expect(executor.interruptTools(conversation.id), isTrue);
      expect(conversation.cancelCompleter!.isCompleted, isFalse);
      provider.finish(0);
      await provider.started[1].future;
      provider.finish(1);
      await executor.whenIdle(conversation.id);
    },
  );
}
