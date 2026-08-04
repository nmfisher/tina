import '../llm/message.dart';
import '../llm/provider.dart';
import '../permissions/policy.dart';

/// Minimal metadata for a stored session — enough to render a picker.
class SessionMeta {
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int messageCount;
  final int conversationCount;

  const SessionMeta({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.messageCount,
    required this.conversationCount,
  });
}

/// A conversation's role within its session — drives how it is rebuilt on
/// resume.
///
/// - [primary]: the interactive main role (delegator, no file tools).
/// - [subAgent]: a delegated sub-agent job — a single role, may itself delegate.
/// - [spawn]: a `/spawn` side panel — a single role, leaf (no delegate).
/// - [branch]: a `/branch` fork of an active conversation — a single role whose
///   transcript is a copy of its parent's history. Leaf (no delegate), like
///   [spawn], but its own kind so the lineage is inspectable in the manifest.
enum ConversationKind { primary, subAgent, spawn, branch }

/// One conversation's entry in a [SessionManifest]. Persists everything needed
/// to rebuild that conversation's agent on resume.
///
/// New fields are all optional in `fromJson` so older manifests (which stored
/// only `id` + `model`) still parse — see [SessionManifest.fromJson] version
/// handling.
class ConversationMeta {
  final String id;

  /// `"provider/model"` reference the conversation ran under. Null (the common
  /// case for older sessions, where it was never stored) falls back to the
  /// account provider on resume.
  final String? model;
  final String? baseUrl;
  final String? providerId;

  /// Human label for the conversation (the model string, or the spawn target).
  final String label;

  final ConversationKind kind;

  /// For [ConversationKind.subAgent] / `.spawn` / `.branch`: the role/workflow
  /// name, used to rebuild the exact tool set (roles are static, so the name
  /// fully determines tools).
  final String? targetName;

  /// The resolved system prompt for this conversation (role identity + any
  /// `[prompts.<role>]` override). Null falls back to resolving from the role
  /// on resume.
  final String? promptOverride;

  /// Serialized [PermissionPolicy] (defaults + static rules). Null falls back
  /// to the session's freshly-built policy on resume.
  final Map<String, dynamic>? policy;

  /// For sub-agents: the parent conversation this was spawned from — lets the
  /// UI nest/relink it on resume.
  final String? parentConversationId;

  const ConversationMeta({
    required this.id,
    this.model,
    this.baseUrl,
    this.providerId,
    this.label = '',
    this.kind = ConversationKind.primary,
    this.targetName,
    this.promptOverride,
    this.policy,
    this.parentConversationId,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'model': model,
        'baseUrl': baseUrl,
        'providerId': providerId,
        'label': label,
        'kind': kind.name,
        if (targetName != null) 'targetName': targetName,
        if (promptOverride != null) 'promptOverride': promptOverride,
        if (policy != null) 'policy': policy,
        if (parentConversationId != null)
          'parentConversationId': parentConversationId,
      };

  factory ConversationMeta.fromJson(Map<String, dynamic> j) {
    final kindName = j['kind'] as String?;
    // `null`/absent → legacy manifest, parsed as primary. An unknown name (a
    // kind a newer/older client wrote that this build doesn't know) falls back
    // to [ConversationKind.spawn] rather than throwing — that rebuilds a
    // role-only, read-only-capable agent, mirroring the provider/policy
    // "fall back, don't fail restore" philosophy. (Unknown kinds are not
    // expected in practice, since kinds are encoded by name and this enum is
    // the only writer.)
    final kind = kindName == null
        ? ConversationKind.primary
        : (ConversationKind.values
                .where((k) => k.name == kindName)
                .firstOrNull ??
            ConversationKind.spawn);
    return ConversationMeta(
      id: j['id'] as String,
      model: j['model'] as String?,
      baseUrl: j['baseUrl'] as String?,
      providerId: j['providerId'] as String?,
      label: (j['label'] as String?) ?? '',
      kind: kind,
      targetName: j['targetName'] as String?,
      promptOverride: j['promptOverride'] as String?,
      policy: (j['policy'] as Map<String, dynamic>?),
      parentConversationId: j['parentConversationId'] as String?,
    );
  }
}

/// Captures the full identity of a conversation at the moment it is created, so
/// it can be written into a [ConversationMeta] in one call. Centralizes the
/// fields every capture site needs so they don't drift.
class ConversationMetaInput {
  final String? model;
  final String? baseUrl;
  final String? providerId;
  final String label;
  final ConversationKind kind;
  final String? targetName;
  final String? promptOverride;
  final Map<String, dynamic>? policy;
  final String? parentConversationId;

  const ConversationMetaInput({
    this.model,
    this.baseUrl,
    this.providerId,
    this.label = '',
    this.kind = ConversationKind.primary,
    this.targetName,
    this.promptOverride,
    this.policy,
    this.parentConversationId,
  });

  /// Capture the identity of a primary conversation (main, `/clear`, new
  /// session) at birth. [providerId] is the registry id (e.g. "anthropic");
  /// [provider] supplies the concrete model; [policy] is the policy the
  /// conversation actually runs under (serialized). [systemPrompt] is the
  /// resolved system prompt when it is already in hand; null falls back to
  /// re-resolving from the (static) main role on resume.
  factory ConversationMetaInput.primary({
    required String providerId,
    required LlmProvider provider,
    String? baseUrl,
    required PermissionPolicy policy,
    String? systemPrompt,
    String? label,
  }) =>
      ConversationMetaInput(
        model: '$providerId/${provider.model}',
        baseUrl: baseUrl,
        providerId: providerId,
        label: label ?? provider.model,
        kind: ConversationKind.primary,
        promptOverride: systemPrompt,
        policy: policy.toJson(),
      );

  /// Capture the identity of a delegated sub-agent job. The job runs a single
  /// role, so [targetName] (the role name) fully determines its tool set on
  /// resume, and [parentConversationId] links it to the conversation that
  /// spawned it. [model] is the full `"provider/model"` reference the job
  /// actually ran under (resolved from its tier, or inherited from the parent).
  factory ConversationMetaInput.subAgent({
    required String model,
    String? providerId,
    required PermissionPolicy policy,
    required String systemPrompt,
    required String targetName,
    required String parentConversationId,
  }) =>
      ConversationMetaInput(
        model: model,
        baseUrl: null,
        providerId: providerId,
        label: targetName,
        kind: ConversationKind.subAgent,
        targetName: targetName,
        promptOverride: systemPrompt,
        policy: policy.toJson(),
        parentConversationId: parentConversationId,
      );

  /// Capture the identity of a `/spawn` side panel. The spawn runs a single
  /// role, so [targetName] (the role name) fully determines its tool set on
  /// resume, and [parentConversationId] links it to the conversation that
  /// spawned it.
  factory ConversationMetaInput.spawn({
    required String providerId,
    required String providerModel,
    String? baseUrl,
    required PermissionPolicy policy,
    required String systemPrompt,
    required String targetName,
    required String parentConversationId,
  }) =>
      ConversationMetaInput(
        model: '$providerId/$providerModel',
        baseUrl: baseUrl,
        providerId: providerId,
        label: '$targetName ($providerModel)',
        kind: ConversationKind.spawn,
        targetName: targetName,
        promptOverride: systemPrompt,
        policy: policy.toJson(),
        parentConversationId: parentConversationId,
      );

  /// Capture the identity of a `/branch` fork. Like a [spawn], a branch runs a
  /// single role (so [targetName] fully determines its tool set on resume) and
  /// links back to its [parentConversationId] — but it is its own
  /// [ConversationKind] so the fork lineage is inspectable in the manifest, and
  /// its on-disk `.jsonl` is seeded with a copy of the parent's history (written
  /// separately by the coordinator that creates the branch). Unlike a sub-agent,
  /// a branch is a leaf and never acquires a `delegate` tool on resume.
  factory ConversationMetaInput.branch({
    required String providerId,
    required String providerModel,
    String? baseUrl,
    required PermissionPolicy policy,
    required String systemPrompt,
    required String targetName,
    required String parentConversationId,
  }) =>
      ConversationMetaInput(
        model: '$providerId/$providerModel',
        baseUrl: baseUrl,
        providerId: providerId,
        label: '$targetName ($providerModel)',
        kind: ConversationKind.branch,
        targetName: targetName,
        promptOverride: systemPrompt,
        policy: policy.toJson(),
        parentConversationId: parentConversationId,
      );
}

/// The persisted shape of a session: its account context (provider id + base
/// URL — never the API key, which is re-derived from the environment on load)
/// plus the conversations it contains and which one is active. Derived facts
/// (timestamps, message counts, titles) are NOT stored here — they're
/// recomputed from the conversation files so a `/compact` rewrite can't stale
/// the index.
class SessionManifest {
  final String id;

  /// Registry provider id, e.g. "anthropic". Read from `providerId` on load,
  /// falling back to the legacy `providerKind` key (older manifests stored the
  /// enum name), then "anthropic". An id that's no longer registered is
  /// handled by the loader (default + notice) rather than failing here.
  final String providerId;
  final String? baseUrl;
  final String activeConversationId;
  final List<ConversationMeta> conversations;

  const SessionManifest({
    required this.id,
    required this.providerId,
    this.baseUrl,
    required this.activeConversationId,
    required this.conversations,
  });

  Map<String, dynamic> toJson() => {
        // v2 adds full per-conversation metadata (see ConversationMeta.toJson).
        'version': 2,
        'id': id,
        'providerId': providerId,
        'baseUrl': baseUrl,
        'activeConversationId': activeConversationId,
        'conversations': conversations.map((c) => c.toJson()).toList(),
      };

  factory SessionManifest.fromJson(Map<String, dynamic> j) => SessionManifest(
        id: j['id'] as String,
        providerId:
            (j['providerId'] ?? j['providerKind'] ?? 'anthropic') as String,
        baseUrl: j['baseUrl'] as String?,
        activeConversationId: (j['activeConversationId'] ?? '') as String,
        conversations: ((j['conversations'] ?? const []) as List)
            .map((c) => ConversationMeta.fromJson(c as Map<String, dynamic>))
            .toList(),
      );
}

/// Abstract conversation persistence. A session is a workspace holding one or
/// more conversations; each conversation is an ordered message history. Keys
/// are two-level: (sessionId, conversationId). Implementations may back this
/// with nested files, SQLite, a remote service, etc. The interface is
/// intentionally narrow: REPL-level operations only, no schema concerns.
abstract class SessionStore {
  /// Create a new empty session and return its id.
  ///
  /// [providerId] identifies the account/registry provider (e.g. "anthropic").
  /// [baseUrl] is an optional override endpoint. The API key is never stored.
  Future<String> createSession({
    required String providerId,
    String? baseUrl,
  });

  /// Add a new (empty) conversation to [sessionId] and return its id. Writes a
  /// [ConversationMeta] carrying the full agent identity so the conversation
  /// can be rebuilt on resume. The first conversation created in a session
  /// becomes the active one. Throws [StateError] if [sessionId] is unknown.
  Future<String> createConversationWithMeta(
      String sessionId, ConversationMetaInput meta);

  /// Legacy shape: create a conversation carrying only its model ref. Default
  /// implementation wraps the model in a [ConversationMetaInput]; the single
  /// concrete store overrides this.
  Future<String> createConversation(String sessionId, {String? model});

  /// Append one message to the end of a conversation.
  ///
  /// Creates the conversation file if necessary. Throws [StateError] if the
  /// session is unknown.
  Future<void> append(String sessionId, String conversationId, Message message);

  /// Replace a conversation's contents atomically — readers see either the old
  /// contents in full or the new contents in full. Used by /compact.
  ///
  /// Throws [StateError] if the session is unknown.
  Future<void> replace(
      String sessionId, String conversationId, List<Message> messages);

  /// Load all messages from a conversation in order.
  ///
  /// Throws [StateError] if the session or conversation is not found.
  Future<List<Message>> loadConversation(
      String sessionId, String conversationId);

  /// Load a session's manifest (structure + active conversation id).
  ///
  /// Throws [StateError] if the session is not found.
  Future<SessionManifest> loadSession(String sessionId);

  /// Make [conversationId] the active conversation of [sessionId].
  ///
  /// The conversation must already exist in the session. Throws [StateError]
  /// if the session or conversation is unknown.
  Future<void> setActiveConversation(String sessionId, String conversationId);

  /// List all sessions, most-recently-updated first.
  Future<List<SessionMeta>> listSessions();

  /// Remove a session and all its conversations.
  ///
  /// Idempotent: no error if the session does not exist.
  Future<void> deleteSession(String sessionId);

  /// Remove one conversation from a session.
  ///
  /// Idempotent: no error if the conversation or session does not exist. If the
  /// removed conversation was the active one, the active pointer falls back to
  /// another conversation in the session (or becomes empty if it was the last).
  Future<void> deleteConversation(String sessionId, String conversationId);

  /// Release any resources held by the store.
  Future<void> close();
}

/// REPL-side wrapper that knows the active (sessionId, conversationId).
/// Holding this in the REPL keeps those details out of the store interface —
/// swapping the backend only requires re-implementing [SessionStore].
///
/// Session and conversation entries are created lazily: the IDs are known from
/// construction, but the on-disk store is only touched on the first [append]
/// (or [replace]) call. A session that is never written to leaves no trace.
class SessionRecorder {
  final SessionStore store;
  String _sessionId;
  String _conversationId;

  /// The provider id recorded in the session manifest on first write.
  final String _providerId;

  /// Optional base URL recorded in the session manifest on first write.
  final String? _baseUrl;

  /// Full conversation identity captured at creation time, written into the
  /// manifest when this recorder creates its FIRST conversation. Null sites
  /// fall back to the legacy model-only meta.
  ConversationMetaInput? _meta;
  ConversationMetaInput? get meta => _meta;

  /// Whether [append] or [replace] has been called at least once (the store
  /// entries exist on disk). When false on teardown, the session is empty and
  /// there is nothing to clean up.
  bool get isInitialized => _initialized;
  bool _initialized = false;

  SessionRecorder(this.store, this._sessionId, this._conversationId,
      {required String providerId, String? baseUrl, ConversationMetaInput? meta})
      : _providerId = providerId,
        _baseUrl = baseUrl,
        _meta = meta;

  String get sessionId => _sessionId;
  String get conversationId => _conversationId;

  /// Set (or override) the captured conversation identity. Used by capture
  /// sites that assemble the meta after the recorder is constructed but before
  /// the first write. No-op once the conversation has reached disk.
  void setMeta(ConversationMetaInput meta) {
    if (_initialized) return;
    _meta = meta;
  }

  /// Ensure the session + this conversation exist on disk WITHOUT writing any
  /// message. Idempotent. Unlike [append]/[replace], registers the meta when the
  /// session is brand-new, so the conversation is restorable on resume even if
  /// its first message is never sent. Used by the interactive /spawn path, which
  /// may register a side panel before the primary session has written anything
  /// (a fresh session persists lazily, so its directory doesn't exist yet).
  Future<void> ensureRegistered() => _lazyInit();

  /// Ensure the session + conversation exist in the store. Idempotent.
  Future<void> _lazyInit() async {
    if (_initialized) return;
    // Create the session if it doesn't already exist (resume reuses an existing
    // session). The store generates its own ID, so we capture it.
    try {
      await store.loadSession(_sessionId);
    } on StateError {
      _sessionId = await store.createSession(
          providerId: _providerId, baseUrl: _baseUrl);
      // Only create a conversation when the created the session too (brand-new
      // session). On resume/switchTo/attach the conversation already exists.
      _conversationId = await store.createConversationWithMeta(
          _sessionId, _meta ?? const ConversationMetaInput());
    }
    _initialized = true;
  }

  Future<void> append(Message m) async {
    await _lazyInit();
    await store.append(_sessionId, _conversationId, m);
  }

  Future<void> replace(List<Message> messages) async {
    await _lazyInit();
    await store.replace(_sessionId, _conversationId, messages);
  }

  /// Begin recording into a brand-new conversation within the same session
  /// (used by `/clear`). The old conversation file is left on disk. Writes a
  /// full meta captured at creation time.
  Future<void> startFresh() async {
    if (!_initialized) await _lazyInit();
    _conversationId = await store.createConversationWithMeta(
        _sessionId, _meta ?? const ConversationMetaInput());
  }

  /// Point this recorder at an EXISTING conversation on disk without creating
  /// a new one or rewriting its meta — used to resume a conversation. The
  /// original meta (model, tools, policy, …) stays intact.
  void attach(String sessionId, String conversationId) {
    _sessionId = sessionId;
    _conversationId = conversationId;
    _initialized = true; // the conversation already exists on disk
  }

  /// Switch to recording into an existing conversation (used by `/resume`).
  void switchTo(String sessionId, String conversationId) {
    attach(sessionId, conversationId);
  }

  /// Verify (post-hoc) that this recorder is attached to a conversation that is
  /// actually listed in the on-disk session manifest. Returns false if not yet
  /// initialized, if the session can't be loaded, or if the conversation isn't
  /// in the manifest.
  ///
  /// This is a diagnostic for tests and the REPL debug helper — [attach] itself
  /// does NOT enforce it (the live re-targeting paths are validated elsewhere:
  /// `/resume` loads the conversation before `switchTo`, and the restore loop
  /// loads it before rehydrating). It therefore cannot detect a message file
  /// that's missing while the meta still lists it — that case is caught by
  /// [SessionRestore.restoreConversation].
  Future<bool> verifyAttach() async {
    if (!_initialized) return false;
    try {
      final manifest = await store.loadSession(_sessionId);
      return manifest.conversations.any((c) => c.id == _conversationId);
    } on StateError {
      return false;
    }
  }

  /// Persist that [conversationId] is now the active conversation of the
  /// current session. Used when the user switches conversations within a session.
  /// Silently skips when the target conversation or session hasn't reached disk
  /// yet (empty session, spawned panels) — the switch is in-memory only.
  Future<void> setActiveConversation(String conversationId) async {
    if (!_initialized) return;
    try {
      await store.setActiveConversation(_sessionId, conversationId);
    } on StateError {
      // Conversation doesn't exist in the store — in-memory only.
    }
  }
}
