import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

/// SP4: locking is decided by the [LockableSessionStore] capability, not a
/// Jsonl type test. A plain store skips locking exactly as non-Jsonl stores
/// always have; a store that declares the capability hands its namespace to
/// [SessionLock.forNamespace].
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('tina-sp4-test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('JsonlSessionStore declares the LockableSessionStore capability', () {
    final store = JsonlSessionStore(tmp);
    addTearDown(store.close);
    expect(store, isA<LockableSessionStore>());
  });

  test('lockNamespaceFor returns the session directory path', () async {
    final store = JsonlSessionStore(tmp);
    addTearDown(store.close);
    final sid = await store.createSession(providerId: 'test');
    final namespace = store.lockNamespaceFor(sid);
    expect(namespace, store.directoryFor(sid).path);
    expect(Directory(namespace).existsSync(), isTrue,
        reason: 'the jsonl namespace is the session directory itself');
  });

  test('SessionLock.forNamespace locks the namespace directory', () async {
    final store = JsonlSessionStore(tmp);
    addTearDown(store.close);
    final sid = await store.createSession(providerId: 'test');
    final lock = SessionLock.forNamespace(store.lockNamespaceFor(sid));
    expect(await lock.acquire(), isNull);
    addTearDown(lock.release);

    // A second acquisition in the same namespace conflicts — the two-process
    // resume guard the launcher relies on.
    final second = SessionLock.forNamespace(store.lockNamespaceFor(sid));
    final conflict = await second.acquire();
    expect(conflict, isNotNull);
    expect(conflict!.toMessage(), isNotEmpty);
  });

  test('a plain SessionStore does not satisfy the capability', () {
    // _InMemoryStore is SessionStore but not LockableSessionStore: the
    // launcher's `store is! LockableSessionStore` early-return must keep
    // matching such backends.
    final store = _PlainStore();
    expect(store, isA<SessionStore>());
    expect(store is LockableSessionStore, isFalse);
  });
}

/// Minimal store-shaped object with no locking capability — stands in for a
/// hypothetical non-file backend (SP5's example) or a test double.
class _PlainStore implements SessionStore {
  @override
  Future<void> append(
      String sessionId, String conversationId, Message message) async {}

  @override
  Future<void> close() async {}

  @override
  Future<String> createConversation(String sessionId, {String? model}) async =>
      'c1';

  @override
  Future<String> createConversationWithMeta(
      String sessionId, ConversationMetaInput meta,
      {String? conversationId}) async {
    throw UnimplementedError();
  }

  @override
  Future<String> createSession(
      {required String providerId,
      String? baseUrl,
      String? cwd,
      String? sessionId}) async {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteConversation(
      String sessionId, String conversationId) async {}

  @override
  Future<void> deleteSession(String sessionId) async {}

  @override
  Future<List<Message>> loadConversation(
      String sessionId, String conversationId) async {
    throw UnimplementedError();
  }

  @override
  Future<SessionManifest> loadSession(String sessionId) async {
    throw UnimplementedError();
  }

  @override
  Future<List<SessionMeta>> listSessions() async => const [];

  @override
  Future<void> replace(
      String sessionId, String conversationId, List<Message> messages) async {}

  @override
  Future<void> setActiveConversation(
      String sessionId, String conversationId) async {}

  @override
  Future<void> updateConversationModel(String sessionId, String conversationId,
      {required String model, String? label}) async {}

  @override
  Future<void> updateConversationTrackers(String sessionId,
      String conversationId,
      {required Map<String, dynamic>? goal,
      required Map<String, dynamic>? plan}) async {}

  @override
  Future<void> updateSessionUsage(String sessionId, int tokens) async {}
}
