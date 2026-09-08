import 'dart:convert';

import 'package:tina_engine/tina_engine.dart';

import '../composition/provider_resolution.dart';
import '../composition/runtime_resources.dart';
import '../config/runtime_config.dart';
import '../conversation.dart';
import '../session.dart';
import '../session_manager.dart';

/// Captured before opening an asynchronous picker. Focus changes cannot retarget it.
class ConversationTarget {
  final String sessionId;
  final String conversationId;
  const ConversationTarget(this.sessionId, this.conversationId);
}

class CreateConversationRequest {
  final ConversationTarget target;
  final String modelReference;
  final ToolProfile profile;
  final String? apiKeyOverride;
  final Map<String, String> promptOverrides;

  CreateConversationRequest({
    required this.target,
    required this.modelReference,
    required this.profile,
    this.apiKeyOverride,
    Map<String, String> promptOverrides = const {},
  }) : promptOverrides = Map.unmodifiable(promptOverrides);
}

class ConversationCreated {
  final String sessionId;
  final String parentConversationId;
  final Conversation conversation;
  const ConversationCreated(
    this.sessionId,
    this.parentConversationId,
    this.conversation,
  );
}

class ChangeModelRequest {
  final ConversationTarget target;
  final String modelReference;
  final String? apiKeyOverride;
  const ChangeModelRequest({
    required this.target,
    required this.modelReference,
    this.apiKeyOverride,
  });
}

class ModelChanged {
  final Conversation conversation;
  final String previousLabel;
  final Object? persistenceError;
  final Object? cleanupError;
  const ModelChanged(
    this.conversation,
    this.previousLabel,
    this.persistenceError,
    this.cleanupError,
  );
}

/// Creation failed and compensation also failed. The allocated id, when known,
/// lets callers inspect the one incomplete record without touching other data.
class ConversationOperationFailure implements Exception {
  final Object cause;
  final Object cleanupError;
  final String? conversationId;
  const ConversationOperationFailure(
    this.cause,
    this.cleanupError,
    this.conversationId,
  );
  @override
  String toString() =>
      '$cause (cleanup failed for $conversationId: $cleanupError)';
}

/// Application-owned construction and persistence, using the existing session registry.
/// The host factory creates an unattached surface; ownership transfers on success.
class ConversationOperations {
  final SessionManager sessions;
  final RuntimeConfig config;
  final AgentPipeline pipeline;
  final LlmProviderFactory providers;
  final SessionStore store;
  final PauseGate? pauseGate;
  final HostInterface Function(String conversationId) hostFactory;

  ConversationOperations({
    required this.sessions,
    required this.config,
    required this.pipeline,
    required this.providers,
    required this.store,
    required this.hostFactory,
    this.pauseGate,
  });

  Session _session(ConversationTarget target) => sessions.all.firstWhere(
    (s) => s.id == target.sessionId,
    orElse: () =>
        throw StateError('Session is no longer open: ${target.sessionId}'),
  );

  Conversation _source(Session session, ConversationTarget target) =>
      session.conversationById(target.conversationId) ??
      (throw StateError(
        'Conversation is no longer open: ${target.conversationId}',
      ));

  void _validate(
    ConversationTarget target,
    Session session,
    Conversation source,
  ) {
    if (!identical(_session(target), session) ||
        !identical(_source(session, target), source)) {
      throw StateError('Conversation changed while the operation was pending');
    }
  }

  Future<ConversationCreated> spawn(CreateConversationRequest request) =>
      _create(request, branch: false);
  Future<ConversationCreated> branch(CreateConversationRequest request) =>
      _create(request, branch: true);

  Future<ConversationCreated> _create(
    CreateConversationRequest request, {
    required bool branch,
  }) async {
    final session = _session(request.target);
    final source = _source(session, request.target);
    // Branching a running source is supported. This is the single snapshot
    // boundary, before the first await; nested tool inputs are copied too.
    final history = branch
        ? [
            for (final message in source.history)
              Message.fromJson(
                jsonDecode(jsonEncode(message.toJson()))
                    as Map<String, dynamic>,
              ),
          ]
        : <Message>[];
    final primaryRecorder = session.conversations.first.recorder;
    if (primaryRecorder == null)
      throw StateError('Session has no persistence anchor');
    final owned = RuntimeResources();
    String? allocatedId;
    try {
      // Preserve the existing side-conversation tuning (512 output tokens,
      // registry-default stream idle timeout, runtime request timeout).
      final provider = providers.build(
        request.modelReference,
        apiKeyOverride: request.apiKeyOverride,
        maxTokens: 512,
        requestTimeout: config.requestTimeout,
      );
      owned.own(provider.close);
      final tools = pipeline.tools.toolSetFor(request.profile);
      final effective = config.safeMode ? stripForSafeMode(tools) : tools;
      final names = effective.map((t) => t.schema.name).toList();
      final bashDecision = config.buildPolicy().check('bash', const {});
      final policy = PermissionPolicy(
        rules: [
          for (final name in names)
            PermissionRule(
              toolName: name,
              pattern: '*',
              decision: name == 'bash'
                  ? bashDecision
                  : PermissionDecision.allow,
            ),
        ],
      );
      final system = resolveMainPrompt(
        pipeline,
        overrides: request.promptOverrides,
        safeMode: config.safeMode,
      );
      final providerId = refProviderForBuild(request.modelReference) ?? '';
      await primaryRecorder.ensureRegistered();
      _validate(request.target, session, source);
      final persistedSessionId = primaryRecorder.sessionId;
      // Lazy primary registration can remint its persisted id; the UI target
      // remains the stable in-memory id, while metadata uses the real anchor.
      final persistedParentId = source.recorder?.conversationId ?? source.id;
      final meta = branch
          ? ConversationMetaInput.branch(
              providerId: providerId,
              providerModel: provider.model,
              policy: policy,
              systemPrompt: system,
              targetName: request.profile.name,
              parentConversationId: persistedParentId,
            )
          : ConversationMetaInput.spawn(
              providerId: providerId,
              providerModel: provider.model,
              policy: policy,
              systemPrompt: system,
              targetName: request.profile.name,
              parentConversationId: persistedParentId,
            );
      final id = await store.createConversationWithMeta(
        persistedSessionId,
        meta,
      );
      allocatedId = id;
      // Compensate only the newly allocated conversation if a later stage fails.
      owned.own(() => store.deleteConversation(persistedSessionId, id));
      _validate(request.target, session, source);
      final host = hostFactory(id);
      owned.own(host.dispose);
      final recorder = SessionRecorder(
        store,
        persistedSessionId,
        id,
        providerId: providerId,
      )..attach(persistedSessionId, id);
      if (branch) await recorder.replace(history);
      _validate(request.target, session, source);
      final conversation = Conversation(
        id: id,
        label: '${request.profile.name} (${request.modelReference})',
        agent: Agent(
          provider: provider,
          tools: ToolRegistry(effective),
          sink: host,
          policy: policy,
          asker: host.askPermission,
          system: system,
          pauseGate: pauseGate,
          maxSteps: 50,
        ),
        provider: provider,
        host: host,
        policy: policy,
        recorder: recorder,
        initialHistory: history,
      );
      session.addConversation(conversation);
      return ConversationCreated(session.id, source.id, conversation);
    } catch (error) {
      try {
        await owned.dispose();
      } catch (cleanupError) {
        throw ConversationOperationFailure(error, cleanupError, allocatedId);
      }
      rethrow;
    }
  }

  /// Preserve the existing immediate-swap rule, including during a running turn.
  /// Build failure leaves the old provider intact. Persistence remains best-effort
  /// as in the TUI, but its failure is returned explicitly to the caller.
  Future<ModelChanged> changeModel(ChangeModelRequest request) async {
    final session = _session(request.target);
    final conversation = _source(session, request.target);
    final provider = providers.build(
      request.modelReference,
      apiKeyOverride: request.apiKeyOverride,
      requestTimeout: config.requestTimeout,
    );
    final previous = conversation.label;
    final role = previous.contains(' (') ? previous.split(' (').first : 'main';
    final cleanupError = conversation.replaceProvider(provider);
    conversation.label = '$role (${request.modelReference.split('/').last})';
    Object? persistenceError;
    try {
      await conversation.recorder?.updateModel(
        request.modelReference,
        label: conversation.label,
      );
    } catch (e) {
      persistenceError = e;
    }
    return ModelChanged(conversation, previous, persistenceError, cleanupError);
  }
}
