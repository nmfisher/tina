import 'dart:async';

import 'package:tina_engine/tina_engine.dart';

import 'package:tina_app/src/session/message_queue.dart';

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

  /// The live `"provider/model"` this conversation runs under. Set at
  /// construction and updated by `/model`, so a sub-agent or workflow node
  /// spawned after a swap inherits the CURRENT model rather than the one the
  /// process started with. Empty when unknown (e.g. a bare legacy ref).
  String modelReference;

  final Agent agent;

  /// The driver this conversation's turns run through — the P5 seam the
  /// [TurnExecutor] speaks to (one turn, abort classification, system prompt,
  /// tool registry, provider swap, compaction). Defaults to an
  /// [AgentDriverAdapter] wrapping [agent], which forwards every member
  /// verbatim — behavior identical to driving the agent directly. A caller
  /// may pass any [AgentDriver] instead (see the `driver` constructor
  /// parameter); the given driver is accepted AS-IS — the constructor does
  /// not verify the pairing, so a caller passing one must ensure it drives
  /// [agent] (shares its history list and provider surface).
  late final AgentDriver driver;
  LlmProvider _provider;

  /// The provider for this conversation. Replacement updates both references
  /// before releasing the old provider, keeping the agent in agreement even
  /// if old-provider cleanup throws.
  LlmProvider get provider => _provider;
  set provider(LlmProvider value) {
    final failure = replaceProvider(value);
    if (failure != null) throw failure;
  }

  /// Installs the replacement atomically; reports old-provider cleanup failure.
  /// Routes through [driver] so a replacement driver stays the single owner of
  /// the provider surface — the adapter forwards to [agent], keeping both
  /// references in agreement exactly as a direct assignment did.
  Object? replaceProvider(LlmProvider value) {
    if (identical(_provider, value)) return null;
    final previous = _provider;
    _provider = value;
    driver.provider = value;
    try {
      previous.close();
    } catch (e) {
      return e;
    }
    return null;
  }

  final HostInterface host;
  final PermissionPolicy policy;
  final List<Message> history = [];
  final MessageQueue messageQueue = MessageQueue();
  final SessionRecorder? recorder;

  /// Completer for the currently running agent turn. Null when idle.
  Completer<void>? cancelCompleter;

  /// Operator interrupt (#31) for the currently running turn: Enter on an
  /// EMPTY input while the queue holds work completes this instead of the
  /// cancel completer — the in-flight tool batch is broken into (its results
  /// ship with the operator line) and the turn ends cleanly, after which the
  /// backlog drains as usual. Fresh per turn (a stale, already-fired signal
  /// would interrupt the next turn's first batch — the engine treats a
  /// completed future as fired); null when idle.
  Completer<void>? toolInterruptCompleter;

  bool isClosed = false;
  Future<void>? turnCompletion;
  void beginClose() {
    isClosed = true;
    messageQueue.clear();
    final cancel = cancelCompleter;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
  }

  /// Busy through cancellation acknowledgement and recording.
  bool get isRunning => cancelCompleter != null;

  Conversation({
    required this.id,
    required this.label,
    required this.agent,
    required LlmProvider provider,
    required this.host,
    required this.policy,
    this.modelReference = '',
    this.recorder,
    List<Message> initialHistory = const [],

    /// Optional replacement driver. Null (the default) wires an
    /// [AgentDriverAdapter] around [agent] — byte-identical to the
    /// pre-driver behavior. When given, it is installed as-is and MUST drive
    /// [agent] (same history list, same provider surface); the constructor
    /// does not assert that pairing.
    AgentDriver? driver,
  }) : _provider = provider,
       driver = driver ?? AgentDriverAdapter(agent) {
    history.addAll(initialHistory);
  }
}
