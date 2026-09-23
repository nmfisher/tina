import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:tina_engine/tina_engine.dart';

void main() {
  late Directory root;
  late JsonlSessionStore store;

  setUp(() {
    root = Directory.systemTemp.createTempSync('tina_index_');
    store = JsonlSessionStore(root);
  });

  tearDown(() async {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  group('JsonlSessionStore as SessionIndex', () {
    test('implements the index directly (no bridge needed)', () {
      expect(store, isA<SessionIndex>());
    });

    test('listSessions lists the saved session, newest first', () async {
      final sid = await store.createSession(
          providerId: 'anthropic', cwd: Directory.current.path);
      final index = store as SessionIndex;
      final sessions = await index.listSessions();
      expect(sessions, hasLength(1));
      expect(sessions.single.id, sid);
    });

    test('cwdFor returns the recorded cwd', () async {
      final project = Directory.systemTemp.createTempSync('tina_proj_');
      addTearDown(() {
        if (project.existsSync()) project.deleteSync(recursive: true);
      });
      final sid = await store.createSession(
          providerId: 'anthropic', cwd: project.path);
      expect(await (store as SessionIndex).cwdFor(sid), project.path);
    });

    test('cwdFor is null for an unknown session (never throws)', () async {
      expect(await (store as SessionIndex).cwdFor('does-not-exist'), isNull);
    });

    test(
        'cwdFor reads only the manifest — a legacy flat session is not '
        'materialized (no write)', () async {
      // A legacy flat <sid>.jsonl has no manifest; the index must report
      // null WITHOUT triggering the copy-then-delete migration (a write).
      final legacy = File(p.join(root.path, 'legacy-session.jsonl'));
      await legacy.writeAsString('');
      expect(await (store as SessionIndex).cwdFor('legacy-session'), isNull);
      // Materialization would have created <root>/legacy-session/session.json
      // and deleted the flat file; neither may have happened.
      expect(
        File(p.join(root.path, 'legacy-session', 'session.json')).existsSync(),
        isFalse,
        reason: 'cwdFor must not materialize a legacy session',
      );
      expect(legacy.existsSync(), isTrue,
          reason: 'cwdFor must not delete the legacy flat file');
    });
  });

  group('SessionIndexStore (bridge for other stores)', () {
    test('bridges listSessions and cwdFor', () async {
      final fake = _FakeStore();
      final index = SessionIndexStore(fake);
      final sid = await fake.createSession(providerId: 'anthropic');
      expect(await index.listSessions(), hasLength(1));
      expect(await index.cwdFor(sid), isNull);
    });

    test('unknown session yields null via the fallback (never throws)',
        () async {
      final index = SessionIndexStore(_FakeStore());
      expect(await index.cwdFor('nope'), isNull);
    });
  });

  group('resolveSessionIndex', () {
    test('returns a SessionIndex backed by the default location', () {
      // Constant default until SP3's config read; it must still be an index
      // (the JSONL store at the default location).
      expect(resolveSessionIndex(), isA<SessionIndex>());
    });
  });
}

/// Minimal non-jsonl backend to exercise the bridge's fallback path
/// (loadSession + StateError → null). Write paths throw UnimplementedError —
/// the index must never call them.
class _FakeStore implements SessionStore {
  final _sessions = <String>[];

  @override
  Future<String> createSession(
      {required String providerId,
      String? baseUrl,
      String? cwd,
      String? sessionId}) async {
    final id = sessionId ?? 'fake-${_sessions.length + 1}';
    _sessions.add(id);
    return id;
  }

  @override
  Future<List<SessionMeta>> listSessions() async => [
        for (final id in _sessions)
          SessionMeta(
            id: id,
            title: id,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
            messageCount: 0,
            conversationCount: 1,
          ),
      ];

  @override
  Future<SessionManifest> loadSession(String sessionId) async {
    if (!_sessions.contains(sessionId)) {
      throw StateError('Session not found: $sessionId');
    }
    return SessionManifest(
        id: sessionId,
        providerId: 'anthropic',
        baseUrl: null,
        cwd: null,
        activeConversationId: '',
        conversations: const [],
        usageTokens: 0,
        transcriptsLocal: true);
  }

  @override
  Future<void> append(String sessionId, String conversationId,
          Message message) =>
      throw UnimplementedError();

  @override
  Future<String> createConversation(String sessionId, {String? model}) =>
      throw UnimplementedError();

  @override
  Future<String> createConversationWithMeta(
          String sessionId, ConversationMetaInput meta) =>
      throw UnimplementedError();

  @override
  Future<List<Message>> loadConversation(
          String sessionId, String conversationId) =>
      throw UnimplementedError();

  @override
  Future<void> replace(String sessionId, String conversationId,
          List<Message> messages) =>
      throw UnimplementedError();

  @override
  Future<void> setActiveConversation(
          String sessionId, String conversationId) =>
      throw UnimplementedError();

  @override
  Future<void> updateConversationModel(String sessionId,
          String conversationId,
          {required String model,
          String? label}) =>
      throw UnimplementedError();

  @override
  Future<void> updateSessionUsage(String sessionId, int tokens) =>
      throw UnimplementedError();

  @override
  Future<void> deleteSession(String sessionId) =>
      throw UnimplementedError();

  @override
  Future<void> deleteConversation(String sessionId, String conversationId) =>
      throw UnimplementedError();

  @override
  Future<void> close() async {}
}
