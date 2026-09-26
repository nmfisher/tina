/// Tool dispatch: guards, liveness, executors, `afterTool`. Split out of
/// loop.dart so the loop file itself stays close to the five steps.
library;

import 'context.dart';
import 'model.dart';
import 'plugin.dart';
import 'registry.dart';

/// The dispatch table one turn dispatches through.
final class Dispatcher {
  Dispatcher({
    required List<AgentPlugin> Function() pluginsInOrder,
    required List<Message> Function() transcriptSnapshot,
    required bool Function(String pluginId) isLive,
    required Map<String, Object> services,
    required Map<String, Object?> turnState,
    required CancelToken cancel,
  })  : _pluginsInOrder = pluginsInOrder,
        _transcript = transcriptSnapshot,
        _isLive = isLive,
        _services = services,
        _turn = turnState,
        _cancel = cancel;

  final List<AgentPlugin> Function() _pluginsInOrder;
  final List<Message> Function() _transcript;
  final bool Function(String pluginId) _isLive;
  final Map<String, Object> _services;
  final Map<String, Object?> _turn;
  final CancelToken _cancel;
  final Map<String, Future<String> Function(Map<String, Object?>)> executors =
      {};

  /// Give a tool its executor. Executors live here, not inside [Tool].
  void registerExecutor(
          String tool, Future<String> Function(Map<String, Object?>) exec) =>
      executors[tool] = exec;

  Context _snap(List<Tool> pinned) => Context(
      transcript: _transcript(),
      tools: List.of(pinned),
      isLive: _isLive,
      services: _services,
      turnState: _turn,
      cancel: _cancel);

  /// Run one tool call through the full gauntlet: liveness, guards,
  /// executor, `afterTool`. Always returns a [ToolResult] — pairing is the
  /// caller's invariant, and this never throws.
  Future<ToolResult> runOne(
      ToolCall call, List<Tool> pinned, Map<String, String> owners) async {
    final owner = owners[call.name];
    if (owner != null && !_isLive(owner)) {
      return ToolResult(
          callId: call.id,
          toolName: call.name,
          ok: false,
          content: 'skipped: plugin $owner left',
          meta: {'skipped': 'plugin-left'});
    }
    for (final p in _pluginsInOrder()) {
      final decision =
          runHook(() => p.beforeTool(_snap(pinned), call)) ??
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
    final exec = executors[call.name];
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
      for (final p in _pluginsInOrder()) {
        final replacement =
            runHook(() => p.afterTool(_snap(pinned), result)) as ToolResult?;
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
