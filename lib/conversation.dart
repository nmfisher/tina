import 'dart:async';

import 'package:tina_engine/tina_engine.dart';

import 'message_queue.dart';

/// A single conversation with its own agent, provider, history, and host. A
/// [Conversation] lives inside a [Session] (which may hold several, each with
/// its own agent and permission policy). Sessions are independent — each
/// conversation can use a different model or provider.
///
/// The conversation is UI-agnostic: it speaks to its frontend through
/// [host], a [HostInterface] that doubles as the agent's [AgentSink]. The
/// terminal host wraps a chat region + spinner; a headless host writes to
/// stdio — this class knows neither.
class Conversation {
  final String id;
  String label;
  final Agent agent;
  LlmProvider _provider;

  /// The provider for this conversation. The setter closes the old provider and
  /// syncs the new one onto the agent, so both references stay in agreement.
  LlmProvider get provider => _provider;
  set provider(LlmProvider value) {
    _provider.close();
    _provider = value;
    agent.provider = value;
  }
  final HostInterface host;
  final PermissionPolicy policy;
  final List<Message> history = [];
  final MessageQueue messageQueue = MessageQueue();
  final SessionRecorder? recorder;

  /// Completer for the currently running agent turn. Null when idle.
  Completer<void>? cancelCompleter;

  /// Whether this conversation has an agent turn currently in flight.
  bool get isRunning =>
      cancelCompleter != null && !cancelCompleter!.isCompleted;

  Conversation({
    required this.id,
    required this.label,
    required this.agent,
    required LlmProvider provider,
    required this.host,
    required this.policy,
    this.recorder,
    List<Message> initialHistory = const [],
  })  : _provider = provider {
    history.addAll(initialHistory);
  }
}
