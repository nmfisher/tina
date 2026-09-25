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
class InMemorySessionStore implements SessionStore, TimestampedSessionStore {
  final _sessions = <String, _MemSession>{};
  int _nextId = 0;

  /// Deterministic clock: bumped by every write, so tests can order
  /// appends/re-points without sleeping.
  DateTime clock = DateTime.fromMillisecondsSinceEpoch(1000000);

  void _tick() => clock = clock.add(const Duration(milliseconds: 10));

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
      String sessionId, ConversationMetaInput meta,
      {String? conversationId}) async {
    final s = _require(sessionId);
    final cid =
        conversationId ?? 'c${s.manifest.conversations.length}-${_nextId++}';
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
    // The first PRIMARY conversation created in a session becomes the
    // active one; panels never anchor.
    if (s.manifest.activeConversationId.isEmpty &&
        meta.kind == ConversationKind.primary) {
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
    s.writes[conversationId] = _tickTime();
  }

  @override
  Future<void> replace(String sessionId, String conversationId,
      List<Message> messages) async {
    final s = _require(sessionId);
    s.messages[conversationId] = List.of(messages);
    s.writes[conversationId] = _tickTime();
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
    final meta = s.manifest.conversations
        .where((c) => c.id == conversationId)
        .firstOrNull;
    if (meta == null) {
      throw StateError('conversation not found: $sessionId/$conversationId');
    }
    if (meta.kind != ConversationKind.primary) {
      // Mirrors the JSONL store: only primaries anchor.
      throw StateError(
          'cannot anchor ${meta.kind.name} conversation '
          '$sessionId/$conversationId — only primaries anchor');
    }
    s.manifest =
        _manifestWith(s.manifest, activeConversationId: conversationId);
    s.pointerWrite = _tickTime();
  }

  @override
  Future<SessionTimestamps> conversationTimestamps(String sessionId) async {
    final s = _require(sessionId);
    final epoch = DateTime.fromMillisecondsSinceEpoch(0);
    return SessionTimestamps([
      for (final c in s.manifest.conversations) s.writes[c.id] ?? epoch,
    ]);
  }

  @override
  Future<DateTime> activePointerUpdatedAt(String sessionId) async =>
      _require(sessionId).pointerWrite ??
      DateTime.fromMillisecondsSinceEpoch(0);

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
        description: _descriptionFor(s, s.manifest.activeConversationId),
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
    // Heal to another PRIMARY on anchor deletion (never a panel), or empty
    // when none remains — the next primary creation anchors.
    final active = s.manifest.activeConversationId == conversationId
        ? remaining
                .where((c) => c.kind == ConversationKind.primary)
                .map((c) => c.id)
                .firstOrNull ??
            ''
        : s.manifest.activeConversationId;
    s.manifest = _manifestWith(s.manifest,
        conversations: remaining, activeConversationId: active);
    _touch(s);
  }

  @override
  Future<void> close() async {} // no-op: nothing held

  DateTime _tickTime() {
    _tick();
    return clock;
  }

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

  /// Mirrors the JSONL store's description: first non-synthetic user text.
  String? _descriptionFor(_MemSession s, String conversationId) {
    String? assistantFallback;
    for (final m in s.messages[conversationId] ?? const <Message>[]) {
      if (m.isSynthetic) continue;
      if (m.role == Role.user) {
        final texts = m.content.whereType<TextBlock>().toList();
        if (texts.isEmpty) continue; // tool-result batch
        final text = texts.map((b) => b.text).join(' ').trim();
        if (text.isNotEmpty) return text.split('\n').first.trim();
      } else if (m.role == Role.assistant && assistantFallback == null) {
        final texts = m.content.whereType<TextBlock>().toList();
        if (texts.isNotEmpty) {
          final text = texts.map((b) => b.text).join(' ').trim();
          if (text.isNotEmpty) assistantFallback = text.split('\n').first.trim();
        }
      }
    }
    return assistantFallback;
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

  /// Per-conversation last-write times (TimestampedSessionStore) and the last
  /// time the active pointer was deliberately set.
  final writes = <String, DateTime>{};
  DateTime? pointerWrite;

  _MemSession({
    required this.manifest,
    required this.createdAt,
    required this.updatedAt,
  });
}
