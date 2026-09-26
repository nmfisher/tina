/// The loop. One file. Five steps: take one input, build the request, call
/// the provider, run the tool calls, append the results and go back to step
/// 2 until the model asks for no tools.
///
/// The core owns truth: this file is the only writer of the transcript.
/// Plugins own decisions, returned through hooks. Bookkeeping lives in
/// [TurnRecorder], pinning in [PinnedTools], prompts in [PromptBuilder],
/// dispatch in [Dispatcher], registration in [PluginRegistry].
library;

import 'context.dart';
import 'dispatch.dart';
import 'model.dart';
import 'pin.dart';
import 'plugin.dart';
import 'prompt.dart';
import 'provider.dart';
import 'registry.dart';
import 'turn.dart';

/// The agent loop.
final class AgentLoop {
  AgentLoop({
    required Provider provider,
    required List<AgentPlugin> plugins,
    Map<String, Object> services = const {},
    this.maxStepsPerTurn = 16,
  })  : _provider = provider,
        _services = Map.of(services) {
    for (final p in plugins) {
      _registry.add(p);
    }
  }

  final Provider _provider;
  final Map<String, Object> _services;
  final int maxStepsPerTurn;
  final PluginRegistry _registry = PluginRegistry();
  final CancelToken _cancel = CancelToken();
  final List<Message> _transcript = [];
  final Map<String, Object?> _turn = {};
  late final Dispatcher _dispatch = Dispatcher(
      pluginsInOrder: _registry.inOrder,
      transcriptSnapshot: () => List.of(_transcript),
      isLive: _registry.contains,
      services: _services,
      turnState: _turn,
      cancel: _cancel);

  /// Register a plugin. A duplicate id throws.
  void addPlugin(AgentPlugin plugin) => _registry.add(plugin);

  /// Remove a plugin. Dispatch re-checks liveness.
  void removePlugin(String id) => _registry.remove(id);

  /// Give a tool its executor. Executors live on the dispatcher.
  void registerExecutor(
          String tool, Future<String> Function(Map<String, Object?>) exec) =>
      _dispatch.registerExecutor(tool, exec);

  /// The one cancellation path.
  void cancel(String why) => _cancel.cancel(why);

  Context _snap(List<Tool> pinned) => Context(
      transcript: List.of(_transcript),
      tools: List.of(pinned),
      isLive: _registry.contains,
      services: _services,
      turnState: _turn,
      cancel: _cancel);

  String _prompt(List<Tool> pinned) =>
      PromptBuilder(pluginsInOrder: _registry.inOrder, snapshot: _snap)
          .build(pinned);

  /// Step 1: take one input. Steps 2–5 run in [_step2to5].
  Future<Outcome> runTurn(Input raw) async {
    _turn.clear();
    final recorder = TurnRecorder([], _snap, _registry.inOrder);
    var input = raw;
    for (final p in _registry.inOrder()) {
      final replacement =
          runHook(() => p.beforeInvocation(_snap(const []), input));
      if (replacement != null) {
        input = replacement;
        recorder.changedBy = p.id; // the last rewrite is recorded
      }
    }
    final user = Message.user(input.text);
    _transcript.add(user);
    recorder.appended.add(user);
    return _step2to5(recorder);
  }

  /// Steps 2–5. The loop body. Nothing else lives here.
  Future<Outcome> _step2to5(TurnRecorder t) async {
    final pinned = PinnedTools(_registry.inOrder());
    for (var step = 0; step < maxStepsPerTurn; step++) {
      if (_cancel.cancelled) {
        return t.finish(
            StopReason.cancelled, 'cancelled: ${_cancel.reason}', _cancel);
      }
      // Step 2: build the request.
      var request = Request(
          systemPrompt: _prompt(pinned.list),
          messages: List.of(_transcript),
          tools: [for (final tool in pinned.list) tool.snapshot()]);
      for (final p in _registry.inOrder()) {
        final replacement = runHook(
            () => p.beforeRequest(_snap(pinned.list), request.snapshot()));
        if (replacement != null) request = replacement;
      }
      // Step 3: call the provider.
      final response = await _provider.call(request);
      t.requests.add(request.snapshot());
      final reply = Message.assistant(response.text,
          toolCalls: [for (final c in response.toolCalls) c.snapshot()]);
      _transcript.add(reply);
      t.appended.add(reply);
      t.responses.add(reply);
      if (response.toolCalls.isEmpty) {
        return t.finish(StopReason.complete, response.text, _cancel);
      }
      // Step 4: run the tool calls.
      for (final call in response.toolCalls) {
        final result = _cancel.cancelled
            ? ToolResult(
                callId: call.id,
                toolName: call.name,
                ok: false,
                content: 'cancelled: ${_cancel.reason}',
                meta: {'cancelled': _cancel.reason})
            : await _dispatch.runOne(call, pinned.list, pinned.ownerOf);
        // Step 5: append the results. Pairing holds even for a denied
        // call: the core writes a result that says so.
        final message = Message.toolResult(result);
        _transcript.add(message);
        t.appended.add(message);
      }
      if (!pinned.stillValid(
          pluginsInOrder: _registry.inOrder,
          isLive: _registry.contains)) {
        return t.finish(StopReason.error, 'tools-changed mid-turn', _cancel);
      }
    }
    return t.finish(
        StopReason.error, 'max-steps ($maxStepsPerTurn) exceeded', _cancel);
  }
}
