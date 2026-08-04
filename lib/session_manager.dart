import 'package:tina_engine/tina_engine.dart';

import 'conversation.dart';
import 'session.dart';

/// Factory function that constructs an [LlmProvider] for a given
/// configuration. Passed in from `bin/tina.dart` to keep the session
/// manager decoupled from concrete provider implementations and the registry.
typedef ProviderFactory = LlmProvider Function(
  String providerId,
  String apiKey,
  String model,
  String? baseUrl,
);

/// Constructs the per-conversation [HostInterface]. Supplied by the app layer
/// (which owns the terminal widgets) so [SessionManager] never touches a UI
/// type. [isActive] is true only for the initial conversation, which is
/// routed to the screen from construction; every conversation created later
/// starts in the background and is routed up by [switchSession] /
/// [switchConversation] via [HostInterface.setActive].
typedef HostFactory = HostInterface Function({
  required String conversationId,
  required bool isActive,
});

/// Builds an [Agent] for a conversation. Supplied by the app layer so the
/// agent's host (its [AgentSink]) is wired in exactly one place without
/// leaking UI details into [SessionManager]. [SessionManager] constructs the
/// per-conversation `provider`, `host`, and `policy` and hands them to the
/// builder; the host is passed as the agent's sink (a [HostInterface] is an
/// [AgentSink]) and as the source of its `asker`. App-level config (tools,
/// max steps, token budget) is captured in the builder's closure.
typedef AgentBuilder = Agent Function({
  required String conversationId,
  required LlmProvider provider,
  required HostInterface host,
  required PermissionPolicy policy,
});

/// Manages multiple independent sessions. Each session is a workspace that can
/// hold several conversations; each conversation has its own agent, provider,
/// history, host, and permission policy. Only the active session's active
/// conversation is routed to the frontend; every other conversation buffers
/// its output through its host (a detached region, a captured log, …).
///
/// This class is UI-agnostic: it speaks only to [HostInterface] and knows
/// nothing about `Screen`, `ChatRegion`, or `Spinner`. The terminal wiring
/// lives in the [HostFactory] / [AgentBuilder] supplied by the app layer.
class SessionManager {
  final SessionStore? sessionStore;
  final ProviderFactory _providerFactory;
  final HostFactory _hostFactory;
  final AgentBuilder _agentBuilder;

  final Map<String, Session> _sessions = {};
  late String _activeSessionId;

  SessionManager({
    required Conversation initialConversation,
    required String initialProviderId,
    required String initialApiKey,
    String? initialBaseUrl,
    String? initialLabel,
    String? initialSessionId,
    required ProviderFactory providerFactory,
    required HostFactory hostFactory,
    required AgentBuilder agentBuilder,
    this.sessionStore,
  })  : _providerFactory = providerFactory,
        _hostFactory = hostFactory,
        _agentBuilder = agentBuilder {
    final session = Session(
      id: (initialSessionId != null && initialSessionId.isNotEmpty)
          ? initialSessionId
          : _generateId(),
      label: initialLabel ?? initialConversation.label,
      providerId: initialProviderId,
      apiKey: initialApiKey,
      baseUrl: initialBaseUrl,
      initialConversation: initialConversation,
    );
    _sessions[session.id] = session;
    _activeSessionId = session.id;
  }

  /// The currently active session id.
  String get activeId => _activeSessionId;

  /// The currently active session (workspace container).
  Session get active => _sessions[_activeSessionId]!;

  /// Whether an active session is currently reachable via [active]. Unlike
  /// [active], this never throws — safe to call during teardown after [closeAll]
  /// has emptied the sessions. (The constructor always opens an initial session,
  /// so the only time this is false is after [closeAll].)
  bool get hasActiveSession => _sessions.containsKey(_activeSessionId);

  /// The active conversation of the active session — the one routed to the
  /// frontend and the target of REPL input.
  Conversation get activeConversation => active.activeConversation;

  /// The id of the active conversation.
  String get activeConversationId => active.activeConversationId;

  /// All sessions.
  List<Session> get all => _sessions.values.toList();

  /// Number of open sessions.
  int get count => _sessions.length;

  /// Switch to a different session. Routes the conversation currently on
  /// screen off it and the new session's active conversation onto it via the
  /// hosts' [HostInterface.setActive].
  Session switchSession(String id) {
    if (id == _activeSessionId) return _sessions[id]!;
    if (!_sessions.containsKey(id)) {
      throw ArgumentError('Unknown session: $id');
    }
    _present(old: activeConversation, next: _sessions[id]!.activeConversation);
    _activeSessionId = id;
    return active;
  }

  /// Switch to a different conversation within the active session.
  ///
  /// Updates the in-memory active pointer and routes the conversation to the
  /// screen. When [persist] is true (the default), also rewrites the session
  /// manifest's `activeConversationId` to [id]. That persist should only happen
  /// for the **primary** conversation: the manifest anchor is what resume uses to
  /// decide which conversation becomes the full-width slot, so it must always be
  /// the primary. Focusing a side panel routes input to it (in-memory) but must
  /// not repoint the anchor at a non-primary, or resume would promote the side
  /// panel to the full-width slot and drop the real primary to a background
  /// replay with no panel.
  Future<Conversation> switchConversation(String id, {bool persist = true}) async {
    final session = active;
    if (id == session.activeConversationId) return session.activeConversation;
    final next = session.conversationById(id);
    if (next == null) throw ArgumentError('Unknown conversation: $id');
    _present(old: session.activeConversation, next: next);
    session.setActiveConversation(id);
    if (persist) {
      final recorder = next.recorder;
      if (recorder != null) await recorder.setActiveConversation(id);
    }
    return next;
  }

  /// Route [old] off the screen and [next] onto it via the hosts. Shared by
  /// [switchSession] and [switchConversation]. After routing [next] on, its
  /// activity signal reflects whether a turn is in flight so its (host's)
  /// spinner state is restored.
  void _present({required Conversation old, required Conversation next}) {
    old.host.setActive(false);
    next.host.setActive(true);
    if (next.isRunning) {
      next.host.setActivity(true);
    } else {
      next.host.setIdle(true);
    }
  }

  /// Create a new session with one fresh conversation. Defaults to the active
  /// session's account context and model. The new session starts in the
  /// background (not routed to the screen).
  Future<Session> createSession({
    String? providerId,
    String? apiKey,
    String? model,
    String? baseUrl,
    String? label,
  }) async {
    final current = active;
    final pid = providerId ?? current.providerId;
    final key = apiKey ?? current.apiKey;
    final mdl = model ?? current.activeConversation.provider.model;
    final url = baseUrl ?? current.baseUrl;

    final sid = sessionStore != null
        ? await sessionStore!.createSession(providerId: pid, baseUrl: url)
        : _generateId();

    final conversation = await _buildConversation(
      sessionId: sid,
      providerId: pid,
      apiKey: key,
      model: mdl,
      baseUrl: url,
      label: label,
      basePolicy: current.activeConversation.policy,
    );

    final session = Session(
      id: sid,
      label: label ?? mdl,
      providerId: pid,
      apiKey: key,
      baseUrl: url,
      initialConversation: conversation,
    );
    _sessions[session.id] = session;
    return session;
  }

  /// Add a new conversation to the active session. Shares the session's account
  /// context and defaults its model to the active conversation's. The new
  /// conversation starts in the background and is NOT made active. (Not yet
  /// wired to the UI — multi-conversation creation lands with the navigation
  /// work.)
  Future<Conversation> createConversation({String? model}) async {
    final current = active;
    final mdl = model ?? current.activeConversation.provider.model;
    final conversation = await _buildConversation(
      sessionId: current.id,
      providerId: current.providerId,
      apiKey: current.apiKey,
      model: mdl,
      baseUrl: current.baseUrl,
      basePolicy: current.activeConversation.policy,
    );
    current.addConversation(conversation);
    return conversation;
  }

  /// Build a background conversation (provider, host, recorder, agent, policy)
  /// from account context. Shared by [createSession] and [createConversation].
  Future<Conversation> _buildConversation({
    required String sessionId,
    required String providerId,
    required String apiKey,
    required String model,
    required String? baseUrl,
    String? label,
    required PermissionPolicy basePolicy,
  }) async {
    final provider = _providerFactory(providerId, apiKey, model, baseUrl);

    // Fresh policy per conversation so remembered (always) rules don't leak
    // across conversations — only the immutable defaults + static rules are
    // inherited; sessionRules starts clean.
    final policy = PermissionPolicy(
      defaults: basePolicy.defaults,
      rules: basePolicy.staticRules,
    );

    // Capture the full per-conversation identity NOW (before the first write)
    // so the manifest meta carries the model, provider, and the policy this
    // conversation actually runs under — everything needed to rebuild the
    // exact agent on resume. The system prompt is left null here: it is
    // re-derived from the static main role on resume, so it needs no storage.
    final meta = ConversationMetaInput.primary(
      providerId: providerId,
      provider: provider,
      baseUrl: baseUrl,
      policy: policy,
      label: label ?? model,
    );

    final conversationId = sessionStore != null
        ? await sessionStore!.createConversationWithMeta(sessionId, meta)
        : _generateId();
    final recorder = sessionStore != null
        ? SessionRecorder(sessionStore!, sessionId, conversationId,
            providerId: providerId, baseUrl: baseUrl, meta: meta)
        : null;

    // The host is built by the app layer (a terminal host wraps a fresh,
    // detached region + spinner; a headless host wires stdio). isActive is
    // false — created conversations start in the background and are routed up
    // only on switch.
    final host = _hostFactory(conversationId: conversationId, isActive: false);

    // The host is the agent's sink AND the source of its asker, so the agent
    // speaks only to the host seam — no UI type reaches [Agent].
    final agent = _agentBuilder(
      conversationId: conversationId,
      provider: provider,
      host: host,
      policy: policy,
    );

    return Conversation(
      id: conversationId,
      label: label ?? model,
      agent: agent,
      provider: provider,
      host: host,
      policy: policy,
      recorder: recorder,
    );
  }

  /// Close and remove a session (and all its conversations). Cannot close the
  /// active session.
  void close(String id) {
    if (id == _activeSessionId) {
      throw StateError('Cannot close the active session');
    }
    final session = _sessions.remove(id);
    if (session != null) {
      for (final c in session.conversations) {
        c.provider.close();
        // dispose()'s body is synchronous (no awaits): it detaches the host's
        // region and tears down its spinner + bus before returning, so the
        // discarded future has already completed its observable work.
        c.host.dispose();
      }
    }
  }

  /// Close one conversation within a session. A session must keep at least one
  /// conversation — close the session instead to remove the last one. If the
  /// closed conversation was on screen, the session's fallback conversation is
  /// routed up. (Not yet wired to the UI.)
  void closeConversation(String sessionId, String conversationId) {
    final session = _sessions[sessionId];
    if (session == null) throw ArgumentError('Unknown session: $sessionId');
    if (session.conversationCount <= 1) {
      throw StateError('Cannot close the last conversation in a session');
    }
    final c = session.conversationById(conversationId);
    if (c == null) throw ArgumentError('Unknown conversation: $conversationId');
    final wasScreened = conversationId == session.activeConversationId &&
        sessionId == _activeSessionId;
    c.provider.close();
    c.host.dispose();
    session.removeConversation(conversationId);
    if (wasScreened) {
      final next = session.activeConversation;
      next.host.setActive(true);
      if (next.isRunning) {
        next.host.setActivity(true);
      } else {
        next.host.setIdle(true);
      }
    }
  }

  /// List sessions with metadata for display.
  List<({String id, String label, bool isActive, bool isRunning, int msgCount})>
      listSessions() {
    return _sessions.values
        .map((s) => (
              id: s.id,
              label: s.label,
              isActive: s.id == _activeSessionId,
              isRunning: s.isRunning,
              msgCount: s.conversations.fold(0, (n, c) => n + c.history.length),
            ))
        .toList();
  }

  /// Forward resize to every conversation's host (across all sessions). A
  /// background host reconciles its buffer without drawing; the active one
  /// redraws.
  void handleResize() {
    for (final session in _sessions.values) {
      for (final c in session.conversations) {
        c.host.handleResize();
      }
    }
  }

  /// Close all sessions and release resources.
  void closeAll() {
    for (final session in _sessions.values) {
      for (final c in session.conversations) {
        c.provider.close();
        c.host.dispose();
      }
    }
    _sessions.clear();
  }

  // -- Internals -----------------------------------------------------------

  String _generateId() {
    final now = DateTime.now();
    final ts =
        '${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}-'
        '${now.hour.toString().padLeft(2, '0')}${now.minute.toString().padLeft(2, '0')}${now.second.toString().padLeft(2, '0')}';
    final r = now.millisecondsSinceEpoch ^ now.microsecond;
    final hex = (r & 0xFFFF).toRadixString(16).padLeft(4, '0');
    return '$ts-$hex';
  }
}
