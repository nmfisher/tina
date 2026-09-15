import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

void main() {
  late Directory dir;
  late JsonlSessionStore store;
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('session-writes-');
    store = JsonlSessionStore(dir);
  });
  tearDown(() async {
    await store.close();
    await dir.delete(recursive: true);
  });

  test('overlapping manifest updates and appends preserve every update',
      () async {
    final sid = await store.createSession(providerId: 'fake');
    final cid = await store.createConversation(sid);
    final writes = <Future<void>>[];
    for (var i = 0; i < 30; i++) {
      writes.add(store.append(sid, cid,
          Message(role: Role.user, content: [TextBlock('message $i')])));
      writes.add(store.updateSessionUsage(sid, i));
      writes.add(store.updateConversationModel(sid, cid, model: 'model $i'));
    }
    await Future.wait(writes);
    final restored = await store.loadConversation(sid, cid);
    expect(restored.map((m) => (m.content.single as TextBlock).text),
        List.generate(30, (i) => 'message $i'));
    final manifest = await store.loadSession(sid);
    expect(manifest.usageTokens, 29);
    expect(manifest.conversations.single.model, 'model 29');
  });

  test('failed write does not poison the queue; replace snapshots live history',
      () async {
    final sid = await store.createSession(providerId: 'fake');
    final cid = await store.createConversation(sid);
    final failed = expectLater(
        store.updateConversationModel(sid, 'missing', model: 'm'),
        throwsStateError);
    final history = <Message>[
      const Message(role: Role.user, content: [TextBlock('snapshot')]),
    ];
    final replace = store.replace(sid, cid, history);
    history.clear();
    final append = store.append(sid, cid,
        const Message(role: Role.assistant, content: [TextBlock('after')]));
    await Future.wait([failed, replace, append]);
    expect(
        (await store.loadConversation(sid, cid))
            .map((m) => (m.content.single as TextBlock).text),
        ['snapshot', 'after']);
  });

  test('concurrent first appends initialize one recorder only once', () async {
    final recorder = SessionRecorder(store, 'new-session', 'placeholder',
        providerId: 'fake');
    await Future.wait(List.generate(
        12,
        (i) => recorder
            .append(Message(role: Role.user, content: [TextBlock('$i')]))));
    expect(await store.listSessions(), hasLength(1));
    final manifest = await store.loadSession(recorder.sessionId);
    expect(manifest.conversations, hasLength(1));
    expect(
        await store.loadConversation(
            recorder.sessionId, recorder.conversationId),
        hasLength(12));
  });
}
