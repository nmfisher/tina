/// The loop. One file. Five steps: take one input, build the request, call
/// the provider, run the tool calls, append the results and go back to step
/// 2 until the model asks for no tools.
library;

import 'dart:collection';

import 'context.dart';
import 'model.dart';
import 'plugin.dart';
import 'provider.dart';

/// The agent loop. The core owns truth: the transcript, the requests, the
/// results — it is the only writer. Plugins own decisions and return them
/// through hooks. A plugin that throws is isolated; its contribution is
/// treated as absent and the turn continues.
final class AgentLoop {
  AgentLoop({
    required Provider provider,
    required List<AgentPlugin> plugins,
    Map<String, Object> services = const {},
    this.maxStepsPerTurn = 16,
  })  : _provider = provider,
        _services = Map.of(services) {
    for (final p in plugins) {
      addPlugin(p);
    }
  }

  final Provider _provider;
  final Map<String, Object> _services;
  final int maxStepsPerTurn;
  final LinkedHashMap<String, AgentPlugin> _registry = LinkedHashMap();
  final Map<String, Future<String> Function(Map<String, Object?>)> _execs = {};
  final CancelToken _cancel = CancelToken();
  final List<Message> _transcript = [];
  final Map<String, Object?> _turn = {};

  /// Plugins in run order: ascending order, ties broken by id.
  List<AgentPlugin> get plugins => _registry.values.toList()
    ..sort((a, b) => a.order != b.order
        ? a.order.compareTo(b.order)
        : a.id.compareTo(b.id));

  /// Register a plugin. A duplicate id is a programming error: throw.
  void addPlugin(AgentPlugin plugin) {
    if (_registry.containsKey(plugin.id)) {
      throw ArgumentError('duplicate plugin id: ${plugin.id}');
    }
    _registry[plugin.id] = plugin;
  }

  /// Remove a plugin. Liveness: dispatch re-checks registration, so a
  /// removed plugin's pending tool call is skipped, not crashed on.
  void removePlugin(String id) => _registry.remove(id);

  /// Give a tool its executor. Executors live here, not inside [Tool].
  void registerExecutor(
          String tool, Future<String> Function(Map<String, Object?>) exec) =>
      _execs[tool] = exec;

  /// The one cancellation path. Checked before the model call and before
  /// each tool.
  void cancel(String why) => _cancel.cancel(why);

  Context _snap(List<Tool> pinned) => Context(
      transcript: List.of(_transcript),
      tools: List.of(pinned),
      isLive: _registry.containsKey,
      services: _services,
      turnState: _turn,
      cancel: _cancel);

  T? _isolate<T>(T? Function() hook) {
    try {
      return hook();
    } catch (_) {
      return null; // one bad plugin must not break the turn
    }
  }

  Future<Outcome> runTurn(Input raw) async {
    _turn.clear();
    final appended = <Message>[];
    String? changedBy;
    var input = raw;
    for (final p in plugins) {
      final replacement =
          _isolate(() => p.beforeInvocation(_snap(const []), input));
      if (replacement != null) {
        input = replacement;
        changedBy = p.id; // sequential rewrites; the last one is recorded
      }
    }
    final user = Message.user(input.text);
    _transcript.add(user);
    appended.add(user);
    final pinned = {
      for (final p in plugins)
        for (final t in p.tools) t.name: t
    };
    final owners = {
      for (final p in plugins)
        for (final t in p.tools) t.name: p.id
    };
    final pinnedTools = pinned.values.toList();
    final requests = <Request>[];
    final responses = <Message>[];

    Outcome finish(StopReason reason, String detail) {
      final outcome = Outcome(
          stopReason: reason,
          messages: [for (final m in appended) m.copy()],
          modelRequests: [for (final r in requests) r.snapshot()],
          modelResponses: [for (final m in responses) m.copy()],
          usage: responses.length,
          detail: detail,
          changedBy: changedBy);
      for (final p in plugins) {
        _isolate(() {
          p.onTurnEnd(_snap(pinnedTools), outcome);
          return null;
        });
      }
      return outcome;
    }

    for (var step = 0; step < maxStepsPerTurn; step++) {
      if (_cancel.cancelled) {
        return finish(StopReason.cancelled, 'cancelled: ${_cancel.reason}');
      }
      var request = Request(
          systemPrompt: _systemPrompt(pinnedTools),
          messages: List.of(_transcript),
          tools: [for (final t in pinnedTools) t.snapshot()]);
      for (final p in plugins) {
        final replacement = _isolate(
            () => p.beforeRequest(_snap(pinnedTools), request.snapshot()));
        if (replacement != null) request = replacement;
      }
      final response = await _provider.call(request);
      requests.add(request.snapshot());
      final reply = Message.assistant(response.text,
          toolCalls: [for (final c in response.toolCalls) c.snapshot()]);
      _transcript.add(reply);
      appended.add(reply);
      responses.add(reply);
      if (response.toolCalls.isEmpty) {
        return finish(StopReason.complete, response.text);
      }
      for (final call in response.toolCalls) {
        var result = _cancel.cancelled
            ? ToolResult(
                callId: call.id,
                toolName: call.name,
                ok: false,
                content: 'cancelled: ${_cancel.reason}',
                meta: {'cancelled': _cancel.reason})
            : await _runOne(call, pinnedTools, owners);
        _transcript.add(Message.toolResult(result));
        appended.add(Message.toolResult(result));
      }
      // Pinning. A plugin that left is not a change — its tools simply
      // became undispatchable, which the liveness check above handles. Any
      // other difference (a live plugin added or removed a tool, a new
      // plugin appeared) rejects the turn.
      final livePinned = {
        for (final name in pinned.keys)
          if (_registry.containsKey(owners[name])) name
      };
      final now = {
        for (final p in plugins)
          for (final t in p.tools) t.name
      };
      if (now.length != livePinned.length || !now.containsAll(livePinned)) {
        return finish(StopReason.error, 'tools-changed mid-turn');
      }
    }
    return finish(StopReason.error, 'max-steps ($maxStepsPerTurn) exceeded');
  }

  String _systemPrompt(List<Tool> pinned) {
    final sections = <String>['You are tina, a terminal coding agent.'];
    for (final p in plugins) {
      final section = _isolate(() => p.systemSection(_snap(pinned)));
      if (section != null && section.isNotEmpty) sections.add(section);
    }
    return sections.join('\n\n');
  }

  Future<ToolResult> _runOne(
      ToolCall call, List<Tool> pinned, Map<String, String> owners) async {
    final owner = owners[call.name];
    if (owner != null && !_registry.containsKey(owner)) {
      return ToolResult(
          callId: call.id,
          toolName: call.name,
          ok: false,
          content: 'skipped: plugin $owner left',
          meta: {'skipped': 'plugin-left'});
    }
    for (final p in plugins) {
      final decision =
          _isolate(() => p.beforeTool(_snap(pinned), call)) ??
              const Decision.allow();
      if (decision.kind != DecisionKind.allow) {
        return decision.replacement ??
            ToolResult(
                callId: call.id,
                toolName: call.name,
                ok: false,
                content: 'denied: ${decision.reason}',
                meta: {
                  'deniedBy': p.id,
                  if (decision.kind == DecisionKind.ask)
                    'denied': 'ask-unresolved'
                });
      }
    }
    final exec = _execs[call.name];
    if (exec == null) {
      return ToolResult(
          callId: call.id,
          toolName: call.name,
          ok: false,
          content: 'no executor for ${call.name}',
          meta: {'error': 'no-executor'});
    }
    try {
      final content = await exec(call.arguments);
      var result = ToolResult(
          callId: call.id, toolName: call.name, ok: true, content: content);
      for (final p in plugins) {
        final replacement =
            _isolate(() => p.afterTool(_snap(pinned), result)) as ToolResult?;
        if (replacement != null) result = replacement.snapshot();
      }
      return result;
    } catch (e) {
      return ToolResult(
          callId: call.id,
          toolName: call.name,
          ok: false,
          content: 'tool threw: $e',
          meta: {'error': 'threw'});
    }
  }
}
