import 'package:tina_engine/src/llm/message.dart';
import 'package:tina_engine/src/persistence/session_store.dart';

/// A non-file `SessionStore` — the SP5 acceptance fixture: proof that the
/// persistence contract is backend-neutral, exercised by the shared contract
/// suite (`session_store_contract_test.dart`). It is a test-only backend, not
/// a shipped one.
///
/// Semantics mirror the documented contract, not the JSONL implementation's
/// file mechanics: no migration, no corrupt-line recovery, no tempfile
/// cleanup — those are backend-specific behaviors and stay in the JSONL test
/// file. What it does implement precisely:
///
/// - `createSession` honors a caller-supplied id and mints a fresh one on
///   collision (never overwrites),
/// - `createConversationWithMeta` writes the full `ConversationMeta`; the
///   first conversation becomes active,
/// - `append` creates the conversation if necessary,
/// - `replace` swaps the conversation contents wholesale,
/// - unknown session/conversation operations throw `StateError`,
/// - `listSessions` derives title from the active conversation's first user
///   text block (same derivation as the JSONL store: whitespace normalized,
///   truncated at 60 with an ellipsis), counts non-empty messages summed
///   across conversations, and sorts most-recently-updated first.
class InMemorySessionStore implements SessionStore {
  final _sessions = <String, _MemSession>{};
  int _nextId = 0;

  @override
  Future<String> createSession({
    required String providerId,
    String? baseUrl,
    String? cwd,
    String? sessionId,
  }) async {
    var id = sessionId ?? _mintId();
    if (_sessions.containsKey(id)) id = _mintId(); // collision → fresh id
    final now = DateTime.now();
    _sessions[id] = _MemSession(
      manifest: SessionManifest(
        id: id,
        providerId: providerId,
        baseUrl: baseUrl,
        cwd: cwd,
        activeConversationId: '',
        conversations: const [],
      ),
      createdAt: now,
      updatedAt: now,
    );
    return id;
  }

  String _mintId() => 'mem-${_nextId++}';

  @override
  Future<String> createConversationWithMeta(
      String sessionId, ConversationMetaInput meta) async {
    final s = _require(sessionId);
    final cid = 'c${s.manifest.conversations.length}-${_nextId++}';
    s.manifest = _manifestWith(s.manifest, conversations: [
      ...s.manifest.conversations,
      ConversationMeta(
        id: cid,
        model: meta.model,
        baseUrl: meta.baseUrl,
        providerId: meta.providerId,
        label: meta.label,
        kind: meta.kind,
        targetName: meta.targetName,
        promptOverride: meta.promptOverride,
        policy: meta.policy,
        parentConversationId: meta.parentConversationId,
      ),
    ]);
    // The first conversation created in a session becomes the active one.
    if (s.manifest.activeConversationId.isEmpty) {
      s.manifest = _manifestWith(s.manifest, activeConversationId: cid);
    }
    _touch(s);
    return cid;
  }

  @override
  Future<String> createConversation(String sessionId, {String? model}) async =>
      createConversationWithMeta(
          sessionId, ConversationMetaInput(model: model));

  @override
  Future<void> append(
      String sessionId, String conversationId, Message message) async {
    final s = _require(sessionId);
    s.messages.putIfAbsent(conversationId, () => []);
    s.messages[conversationId]!.add(message);
    _touch(s);
  }

  @override
  Future<void> replace(String sessionId, String conversationId,
      List<Message> messages) async {
    final s = _require(sessionId);
    s.messages[conversationId] = List.of(messages);
    _touch(s);
  }

  @override
  Future<List<Message>> loadConversation(
      String sessionId, String conversationId) async {
    final s = _require(sessionId);
    if (!s.messages.containsKey(conversationId)) {
      throw StateError('conversation not found: $sessionId/$conversationId');
    }
    return List.of(s.messages[conversationId]!);
  }

  @override
  Future<SessionManifest> loadSession(String sessionId) async =>
      _require(sessionId).manifest;

  @override
  Future<void> setActiveConversation(
      String sessionId, String conversationId) async {
    final s = _require(sessionId);
    if (!s.manifest.conversations.any((c) => c.id == conversationId)) {
      throw StateError('conversation not found: $sessionId/$conversationId');
    }
    s.manifest =
        _manifestWith(s.manifest, activeConversationId: conversationId);
    _touch(s);
  }

  @override
  Future<void> updateConversationModel(String sessionId,
      String conversationId,
      {required String model,
      String? label}) async {
    final s = _require(sessionId);
    final idx = s.manifest.conversations
        .indexWhere((c) => c.id == conversationId);
    if (idx < 0) {
      throw StateError('conversation not found: $sessionId/$conversationId');
    }
    final old = s.manifest.conversations[idx];
    final ref = model.split('/');
    s.manifest = _manifestWith(s.manifest, conversations: [
      for (final c in s.manifest.conversations)
        if (c.id == conversationId)
          ConversationMeta(
            id: old.id,
            model: model,
            baseUrl: old.baseUrl,
            providerId: ref.first,
            label: label ?? old.label,
            kind: old.kind,
            targetName: old.targetName,
            promptOverride: old.promptOverride,
            policy: old.policy,
            parentConversationId: old.parentConversationId,
            // Unrelated to the model swap — carried through, as on disk.
            goal: old.goal,
            plan: old.plan,
          )
        else
          c,
    ]);
    _touch(s);
  }

  @override
  Future<void> updateConversationTrackers(String sessionId,
      String conversationId,
      {required Map<String, dynamic>? goal,
      required Map<String, dynamic>? plan}) async {
    final s = _require(sessionId);
    final idx = s.manifest.conversations
        .indexWhere((c) => c.id == conversationId);
    if (idx < 0) {
      throw StateError('conversation not found: $sessionId/$conversationId');
    }
    s.manifest = _manifestWith(s.manifest, conversations: [
      for (final c in s.manifest.conversations)
        if (c.id == conversationId)
          ConversationMeta(
            id: c.id,
            model: c.model,
            baseUrl: c.baseUrl,
            providerId: c.providerId,
            label: c.label,
            kind: c.kind,
            targetName: c.targetName,
            promptOverride: c.promptOverride,
            policy: c.policy,
            parentConversationId: c.parentConversationId,
            goal: goal,
            plan: plan,
          )
        else
          c,
    ]);
    _touch(s);
  }

  @override
  Future<void> updateSessionUsage(String sessionId, int tokens) async {
    final s = _require(sessionId);
    s.manifest =
        _manifestWith(s.manifest, usageTokens: tokens < 0 ? 0 : tokens);
    _touch(s);
  }

  @override
  Future<List<SessionMeta>> listSessions() async {
    final metas = <SessionMeta>[];
    for (final s in _sessions.values) {
      final title =
          _titleFor(s, s.manifest.activeConversationId) ?? '(empty)';
      var count = 0;
      for (final msgs in s.messages.values) {
        count += msgs.length;
      }
      metas.add(SessionMeta(
        id: s.manifest.id,
        title: title,
        createdAt: s.createdAt,
        updatedAt: s.updatedAt,
        messageCount: count,
        conversationCount: s.manifest.conversations.length,
        cwd: s.manifest.cwd,
      ));
    }
    metas.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return metas;
  }

  @override
  Future<void> deleteSession(String sessionId) async {
    _sessions.remove(sessionId); // idempotent
  }

  @override
  Future<void> deleteConversation(
      String sessionId, String conversationId) async {
    final s = _sessions[sessionId];
    if (s == null) return; // idempotent
    // No-op only when the conversation is known to neither the manifest nor
    // the messages (mirrors the JSONL store: a missing transcript file is
    // tolerated, but a manifest entry is still removed).
    final inManifest =
        s.manifest.conversations.any((c) => c.id == conversationId);
    final hadMessages = s.messages.remove(conversationId) != null;
    if (!inManifest && !hadMessages) return;
    final remaining = [
      for (final c in s.manifest.conversations)
        if (c.id != conversationId) c
    ];
    var active = s.manifest.activeConversationId == conversationId
        ? (remaining.isEmpty ? '' : remaining.first.id)
        : s.manifest.activeConversationId;
    s.manifest = _manifestWith(s.manifest,
        conversations: remaining, activeConversationId: active);
    _touch(s);
  }

  @override
  Future<void> close() async {} // no-op: nothing held

  void _touch(_MemSession s) => s.updatedAt = DateTime.now();

  _MemSession _require(String sessionId) {
    final s = _sessions[sessionId];
    if (s == null) throw StateError('session not found: $sessionId');
    return s;
  }

  String? _titleFor(_MemSession s, String conversationId) {
    for (final m in s.messages[conversationId] ?? const <Message>[]) {
      if (m.role != Role.user) continue;
      for (final b in m.content) {
        if (b is TextBlock && b.text.trim().isNotEmpty) return _summarize(b.text);
      }
    }
    return null;
  }

  static String _summarize(String text) {
    final cleaned = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    return cleaned.length <= 60 ? cleaned : '${cleaned.substring(0, 60)}…';
  }

  static SessionManifest _manifestWith(SessionManifest m,
      {List<ConversationMeta>? conversations,
      String? activeConversationId,
      int? usageTokens}) {
    return SessionManifest(
      id: m.id,
      providerId: m.providerId,
      baseUrl: m.baseUrl,
      cwd: m.cwd,
      activeConversationId: activeConversationId ?? m.activeConversationId,
      conversations: conversations ?? m.conversations,
      usageTokens: usageTokens ?? m.usageTokens,
      transcriptsLocal: m.transcriptsLocal,
    );
  }
}

class _MemSession {
  SessionManifest manifest;
  final DateTime createdAt;
  DateTime updatedAt;
  final messages = <String, List<Message>>{};

  _MemSession({
    required this.manifest,
    required this.createdAt,
    required this.updatedAt,
  });
}
