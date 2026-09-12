import 'dart:async';
import 'package:tina_app/src/session/conversation_selection.dart';
import 'selection_presenter.dart';
import 'package:tina_engine/tina_engine.dart';

import 'package:tina_app/src/session/conversation.dart';
import 'package:tina_app/src/composition/runtime_resources.dart';
import 'package:tina_app/src/session/session.dart';

/// Factory function that constructs an [LlmProvider] for a given
/// configuration. Passed in from `bin/tina.dart` to keep the session
/// manager decoupled from concrete provider implementations and the registry.
typedef ProviderFactory =
    LlmProvider Function(
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
typedef HostFactory =
    HostInterface Function({
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
///
/// The builder returns the conversation's [AgentDriver] — the unit of
/// execution — so the scope-selected driver factory survives into the
/// conversation. Returning the bare [Agent] here (the pre-fix shape) made
/// the manager re-wrap a fresh adapter around it and silently discard the
/// composed driver.
typedef AgentBuilder =
    AgentDriver Function({
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

  /// The P5 replacement seam: wraps (or replaces) the driver every
  /// conversation built by this manager runs through. Receives the built
  /// [Agent] and returns the [AgentDriver] handed to the [Conversation];
  /// the executor then speaks to that driver instead of the agent. A test (or
  /// profile) can therefore script the whole turn loop without editing this
  /// coordinator. Null (the default) means [AgentDriverAdapter.new] — each
  /// conversation gets an adapter around its own agent, which reproduces
  /// today's behavior byte for byte.
  final AgentDriver Function(Agent agent)? driverWrapper;

  /// Working directory this process is operating in, stamped into the manifest
  /// of any session created in-REPL so `--continue` can scope to the current
  /// folder. Supplied by the app layer; null disables folder scoping.
  final String? cwd;

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
    this.driverWrapper,
    this.cwd,
  }) : _providerFactory = providerFactory,
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
  ConversationSelection selectSession(String id) {
    final session = _sessions[id];
    if (session == null) throw ArgumentError('Unknown session: $id');
    final previous = activeConversation;
    _activeSessionId = id;
    session.unread = 0;
    return ConversationSelection(id, previous, session.activeConversation);
  }

  ConversationSelection selectConversation(String id) {
    final session = active;
    final next = session.conversationById(id);
    if (next == null) throw ArgumentError('Unknown conversation: $id');
    final selection = ConversationSelection(
      session.id,
      session.activeConversation,
      next,
    );
    session.setActiveConversation(id);
    return selection;
  }

  /// Persist only deliberate primary selections. Side-panel focus passes false.
  Future<void> persistSelection(
    ConversationSelection selection, {
    bool persist = true,
  }) async {
    if (persist && selection.changed) {
      await selection.next.recorder?.setActiveConversation(selection.next.id);
    }
  }

  /// Compatibility presentation wrappers. New frontend callers use selection
  /// results and apply their own presentation adapter.
  Session switchSession(String id) {
    presentConversationSelection(selectSession(id));
    return active;
  }

  Future<Conversation> switchConversation(
    String id, {
    bool persist = true,
  }) async {
    final selection = selectConversation(id);
    presentConversationSelection(selection);
    await persistSelection(selection, persist: persist);
    return selection.next;
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
        ? await sessionStore!.createSession(
            providerId: pid,
            baseUrl: url,
            cwd: cwd,
          )
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
    if (_closing != null) throw StateError('Session manager is closing');
    final provider = _providerFactory(providerId, apiKey, model, baseUrl);
    final resources = RuntimeResources()..own(provider.close);
    try {
      // Fresh policy per conversation so remembered (always) rules don't leak
      // across conversations — only the immutable defaults + static rules +
      // the current mode are inherited; sessionRules starts clean.
      final policy = PermissionPolicy(
        defaults: basePolicy.defaults,
        rules: basePolicy.staticRules,
        modeSource: basePolicy,
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
          ? SessionRecorder(
              sessionStore!,
              sessionId,
              conversationId,
              providerId: providerId,
              baseUrl: baseUrl,
              cwd: cwd,
              meta: meta,
            )
          : null;

      // The host is built by the app layer (a terminal host wraps a fresh,
      // detached region + spinner; a headless host wires stdio). isActive is
      // false — created conversations start in the background and are routed up
      // only on switch.
      final host = _hostFactory(
        conversationId: conversationId,
        isActive: false,
      );
      resources.own(host.dispose);

      // The host is the conversation's sink AND the source of its asker, so
      // the driver speaks only to the host seam — no UI type reaches the
      // build. The builder returns the conversation's DRIVER (the composed
      // one, when a factory is mounted), so it survives into the conversation
      // instead of being unwrapped and re-adapted.
      final driver = _agentBuilder(
        conversationId: conversationId,
        provider: provider,
        host: host,
        policy: policy,
      );

      // The P5 seam: when a wrapper is wired it REPLACES the built driver,
      // receiving the underlying agent when the driver is an adapter. Null
      // (the default) keeps the built driver as-is — an adapter around the
      // plain build reproduces the pre-driver behavior byte for byte.
      final underlying = driver is AgentDriverAdapter ? driver.agent : null;
      return Conversation(
        id: conversationId,
        label: label ?? model,
        provider: provider,
        host: host,
        policy: policy,
        modelReference: '$providerId/$model',
        recorder: recorder,
        driver: driverWrapper == null || underlying == null
            ? driver
            : driverWrapper!(underlying),
      );
    } catch (_) {
      try {
        await resources.dispose();
      } catch (_) {}
      rethrow;
    }
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
        _deferRelease(c);
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
    final wasScreened =
        conversationId == session.activeConversationId &&
        sessionId == _activeSessionId;
    _deferRelease(c);
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
  List<
    ({
      String id,
      String label,
      bool isActive,
      bool isRunning,
      int msgCount,
      int unread,
    })
  >
  listSessions() {
    return _sessions.values
        .map(
          (s) => (
            id: s.id,
            label: s.label,
            isActive: s.id == _activeSessionId,
            isRunning: s.isRunning,
            msgCount: s.conversations.fold(0, (n, c) => n + c.history.length),
            unread: s.unread,
          ),
        )
        .toList();
  }

  /// Record that [conversationId] produced output while in the background,
  /// bumping its session's unread counter. No-op for the active session (its
  /// output is on screen) and for unknown conversations. Returns the session
  /// id only on the 0→1 transition (the first background event since it was
  /// last foregrounded) so callers can refresh a badge once per burst instead
  /// of on every streamed chunk.
  String? markBackgroundActivity(String conversationId) {
    for (final s in _sessions.values) {
      if (s.id == _activeSessionId) continue;
      if (s.conversationById(conversationId) != null) {
        final wasZero = s.unread == 0;
        s.unread++;
        return wasZero ? s.id : null;
      }
    }
    return null;
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
  Future<void>? _closing;
  final _pendingReleases = <Future<void>>[];
  void _deferRelease(Conversation conversation) {
    final future = _releaseConversation(conversation);
    _pendingReleases.add(future);
    unawaited(future.catchError((Object _) {}));
  }

  Future<void> closeAll() {
    if (_closing != null) return _closing!;
    final resources = RuntimeResources();
    for (final session in _sessions.values) {
      for (final c in session.conversations) {
        c.beginClose();
        resources.own(() => _releaseConversation(c));
      }
    }
    for (final pending in _pendingReleases) {
      resources.own(() => pending);
    }
    _sessions.clear();
    return _closing = resources.dispose();
  }

  Future<void> _releaseConversation(Conversation conversation) {
    conversation.beginClose();
    final resources = RuntimeResources()
      ..own(conversation.host.dispose)
      ..own(conversation.provider.close);
    final pending = conversation.turnCompletion;
    if (pending == null) return resources.dispose();
    return () async {
      await pending;
      await resources.dispose();
    }();
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
