import 'package:tina_engine/tina_engine.dart';

/// An in-memory [SessionStore] for tests.
///
/// Mirrors the semantics of the on-disk store without touching the filesystem.
/// The first conversation created in a session becomes the active one;
/// [deleteConversation] falls back the active pointer to another conversation
/// (or clears it when the last conversation is removed).
class MemorySessionStore implements SessionStore {
  final Map<String, SessionManifest> _manifests = {};
  final Map<String, List<Message>> _conversations = {};
  final Map<String, DateTime> _createdAt = {};
  final Map<String, DateTime> _updatedAt = {};
  int _sessionCounter = 0;
  int _convCounter = 0;

  /// Look up a conversation's metadata within a session. Not part of the
  /// [SessionStore] interface, but useful for tests that assert on manifest
  /// structure.
  ConversationMeta? metaFor(String sessionId, String conversationId) =>
      _manifests[sessionId]
          ?.conversations
          .where((c) => c.id == conversationId)
          .firstOrNull;

  @override
  Future<String> createSession({
    required String providerId,
    String? baseUrl,
    String? cwd,
    DateTime? updatedAt,
  }) async {
    final id = 's${++_sessionCounter}';
    final now = updatedAt ?? DateTime.now();
    _manifests[id] = SessionManifest(
      id: id,
      providerId: providerId,
      baseUrl: baseUrl,
      cwd: cwd,
      activeConversationId: '',
      conversations: const [],
    );
    _createdAt[id] = now;
    _updatedAt[id] = now;
    return id;
  }

  @override
  Future<String> createConversation(String sessionId, {String? model}) =>
      createConversationWithMeta(
          sessionId, ConversationMetaInput(model: model));

  @override
  Future<String> createConversationWithMeta(
      String sessionId, ConversationMetaInput input) async {
    final manifest = _manifests[sessionId];
    if (manifest == null) throw StateError('Session not found: $sessionId');
    final id = 'c${++_convCounter}';
    _conversations[id] = <Message>[];
    final conversations = [
      ...manifest.conversations,
      ConversationMeta(
        id: id,
        model: input.model,
        baseUrl: input.baseUrl,
        providerId: input.providerId,
        label: input.label,
        kind: input.kind,
        targetName: input.targetName,
        promptOverride: input.promptOverride,
        policy: input.policy,
        parentConversationId: input.parentConversationId,
      ),
    ];
    _manifests[sessionId] = SessionManifest(
      id: manifest.id,
      providerId: manifest.providerId,
      baseUrl: manifest.baseUrl,
      cwd: manifest.cwd,
      activeConversationId: manifest.activeConversationId.isEmpty
          ? id
          : manifest.activeConversationId,
      conversations: conversations,
    );
    return id;
  }

  @override
  Future<void> append(
      String sessionId, String conversationId, Message message) async {
    (_conversations[conversationId] ??= <Message>[]).add(message);
  }

  @override
  Future<void> replace(
      String sessionId, String conversationId, List<Message> messages) async {
    _conversations[conversationId] = List<Message>.of(messages);
  }

  @override
  Future<List<Message>> loadConversation(
      String sessionId, String conversationId) async {
    final messages = _conversations[conversationId];
    if (messages == null) {
      throw StateError('Conversation not found: $sessionId/$conversationId');
    }
    return messages;
  }

  @override
  Future<SessionManifest> loadSession(String sessionId) async =>
      _manifests[sessionId] ??
      (throw StateError('Session not found: $sessionId'));

  @override
  Future<void> setActiveConversation(
      String sessionId, String conversationId) async {
    final manifest = _manifests[sessionId];
    if (manifest == null) throw StateError('Session not found: $sessionId');
    if (!manifest.conversations.any((c) => c.id == conversationId)) {
      throw StateError(
          'Conversation not found in session: $sessionId/$conversationId');
    }
    _manifests[sessionId] = SessionManifest(
      id: manifest.id,
      providerId: manifest.providerId,
      baseUrl: manifest.baseUrl,
      cwd: manifest.cwd,
      activeConversationId: conversationId,
      conversations: manifest.conversations,
    );
  }

  @override
  Future<List<SessionMeta>> listSessions() async {
    final out = <SessionMeta>[];
    for (final entry in _manifests.entries) {
      final sid = entry.key;
      final manifest = entry.value;
      var totalCount = 0;
      for (final c in manifest.conversations) {
        totalCount += (_conversations[c.id]?.length ?? 0);
      }
      final updated = _updatedAt[sid]!;
      out.add(SessionMeta(
        id: sid,
        title: '(test)',
        createdAt: _createdAt[sid] ?? updated,
        updatedAt: updated,
        messageCount: totalCount,
        conversationCount: manifest.conversations.length,
        cwd: manifest.cwd,
      ));
    }
    out.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return out;
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    _manifests.remove(sessionId);
    _createdAt.remove(sessionId);
    _updatedAt.remove(sessionId);
  }

  @override
  Future<void> deleteConversation(
      String sessionId, String conversationId) async {
    _conversations.remove(conversationId);
    final manifest = _manifests[sessionId];
    if (manifest == null) return;
    final remaining =
        manifest.conversations.where((c) => c.id != conversationId).toList();
    final active = manifest.activeConversationId == conversationId
        ? (remaining.isEmpty ? '' : remaining.first.id)
        : manifest.activeConversationId;
    _manifests[sessionId] = SessionManifest(
      id: manifest.id,
      providerId: manifest.providerId,
      baseUrl: manifest.baseUrl,
      cwd: manifest.cwd,
      activeConversationId: active,
      conversations: remaining,
    );
  }

  @override
  Future<void> close() async {}
}
