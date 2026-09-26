/// The loop. One file. Five steps, top to bottom:
///
/// 1. take the input
/// 2. build the request
/// 3. call the model
/// 4. run the tool calls
/// 5. append the results, and repeat from step 2 until the model asks for
///    no tools
///
/// The core owns truth: this file is the only writer of the transcript.
/// Plugins own decisions, returned through hooks. Registration, snapshots,
/// the prompt join, pinning, dispatch and turn bookkeeping all live here —
/// each is a few lines, and pulling any of them out would make a reader
/// jump between files to follow one turn.
library;

import 'dart:collection';

import 'context.dart';
import 'model.dart';
import 'plugin.dart';
import 'provider.dart';

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
      addPlugin(p);
    }
  }

  final Provider _provider;
  final Map<String, Object> _services;
  final int maxStepsPerTurn;

  /// Plugins in registration order. A duplicate id throws here.
  final LinkedHashMap<String, AgentPlugin> _byId = LinkedHashMap();

  /// The one cancellation path. Set once; there is no unset.
  final CancelToken _cancel = CancelToken();
  final List<Message> _transcript = [];

  /// Run order: ascending [AgentPlugin.order], ties broken by id, so the
  /// sequence is the same every run.
  List<AgentPlugin> _inOrder() {
    final list = _byId.values.toList()
      ..sort((a, b) =>
          a.order != b.order ? a.order.compareTo(b.order) : a.id.compareTo(b.id));
    return list;
  }

  /// Register a plugin. A duplicate id throws.
  void addPlugin(AgentPlugin plugin) {
    if (_byId.containsKey(plugin.id)) {
      throw ArgumentError('duplicate plugin id: ${plugin.id}');
    }
    _byId[plugin.id] = plugin;
  }

  /// Remove a plugin. Dispatch re-checks liveness.
  void removePlugin(String id) => _byId.remove(id);

  /// Give a tool its executor. Executors are not part of [Tool].
  void registerExecutor(
          String tool, Future<String> Function(Map<String, Object?>) exec) =>
      _executors[tool] = exec;
  final Map<String, Future<String> Function(Map<String, Object?>)> _executors =
      {};

  /// The one cancellation path.
  void cancel(String why) => _cancel.cancel(why);

  /// What a plugin sees right now: transcript up to now, the tools pinned
  /// for this turn, read-only registries, the shared cancel token.
  Context _snap(List<Tool> pinned) => Context(
      transcript: List.of(_transcript),
      tools: List.of(pinned),
      isLive: _byId.containsKey,
      services: _services,
      turnState: _turn,
      cancel: _cancel);
  final Map<String, Object?> _turn = {};

  /// One plugin hook, isolated: a plugin that throws has its contribution
  /// treated as absent and the turn continues.
  static T? _runHook<T>(T? Function() hook) {
    try {
      return hook();
    } catch (_) {
      return null;
    }
  }

  /// The system prompt: the core's header, then one section per plugin in
  /// order, joined by a blank line. A plugin returns a section, never a
  /// whole prompt; a throwing plugin's section is absent.
  String _prompt(List<Tool> pinned,
      {String header = 'You are tina, a terminal coding agent.'}) {
    final sections = <String>[header];
    for (final p in _inOrder()) {
      try {
        final section = p.systemSection(_snap(pinned));
        if (section != null && section.isNotEmpty) sections.add(section);
      } catch (_) {
        // one bad plugin must not break every prompt
      }
    }
    return sections.join('\n\n');
  }

  /// The five steps of one turn, in order, in one pass.
  Future<Outcome> runTurn(Input raw) async {
    // ------------------------------------------------------------------
    // Step 1: take the input. Plugins may rewrite it, in order; the last
    // rewrite is the one the outcome records.
    // ------------------------------------------------------------------
    _turn.clear();
    final pinnedMap = {
      for (final p in _inOrder())
        for (final t in p.tools) t.name: t
    };
    final ownerOf = {
      for (final p in _inOrder())
        for (final t in p.tools) t.name: p.id
    };
    final pinned = [for (final t in pinnedMap.values) t];
    final appended = <Message>[];
    final requests = <Request>[];
    final responses = <Message>[];
    String? changedBy;

    // The single exit: build the outcome, fan out onTurnEnd, return.
    // A throwing listener is isolated; the others still get the event.
    Outcome finish(StopReason reason, String detail) {
      final outcome = Outcome(
          stopReason: reason,
          messages: [for (final m in appended) m.copy()],
          modelRequests: [for (final r in requests) r.snapshot()],
          modelResponses: [for (final m in responses) m.copy()],
          usage: responses.length,
          detail: detail,
          changedBy: changedBy);
      for (final p in _inOrder()) {
        try {
          p.onTurnEnd(_snap(pinned), outcome);
        } catch (_) {
          // one bad plugin must not break the turn end
        }
      }
      return outcome;
    }

    var input = raw;
    for (final p in _inOrder()) {
      final replacement =
          _runHook(() => p.beforeInvocation(_snap(const []), input));
      if (replacement != null) {
        input = replacement;
        changedBy = p.id; // the last rewrite is recorded
      }
    }
    final user = Message.user(input.text);
    _transcript.add(user);
    appended.add(user);

    // ------------------------------------------------------------------
    // Steps 2–5. Repeat until the model asks for no tools, the turn is
    // cancelled, or the step budget runs out.
    // ------------------------------------------------------------------
    for (var step = 0; step < maxStepsPerTurn; step++) {
      if (_cancel.cancelled) {
        return finish(StopReason.cancelled, 'cancelled: ${_cancel.reason}');
      }

      // Step 2: build the request — system prompt, transcript snapshot,
      // the pinned tools — then let plugins transform it, in order.
      var request = Request(
          systemPrompt: _prompt(pinned),
          messages: List.of(_transcript),
          tools: [for (final tool in pinned) tool.snapshot()]);
      for (final p in _inOrder()) {
        final replacement = _runHook(
            () => p.beforeRequest(_snap(pinned), request.snapshot()));
        if (replacement != null) request = replacement;
      }

      // Step 3: call the model.
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

      // Step 4: run the tool calls. Liveness first: a plugin that left
      // mid-turn has its call skipped, not crashed on. Then guards, in
      // order — all must pass; `ask` with no UI resolves to deny. Then
      // the executor; then `afterTool`, in order, which may replace the
      // result the core records.
      for (final call in response.toolCalls) {
        ToolResult result;
        if (_cancel.cancelled) {
          result = ToolResult(
              callId: call.id,
              toolName: call.name,
              ok: false,
              content: 'cancelled: ${_cancel.reason}',
              meta: {'cancelled': _cancel.reason});
        } else {
          final owner = ownerOf[call.name];
          if (owner != null && !_byId.containsKey(owner)) {
            result = ToolResult(
                callId: call.id,
                toolName: call.name,
                ok: false,
                content: 'skipped: plugin $owner left',
                meta: {'skipped': 'plugin-left'});
          } else {
            ToolResult? denied;
            for (final p in _inOrder()) {
              final decision =
                      _runHook(() => p.beforeTool(_snap(pinned), call)) ??
                  const Decision.allow();
              if (decision.kind != DecisionKind.allow) {
                denied = decision.replacement ??
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
                break;
              }
            }
            final exec = _executors[call.name];
            if (denied != null) {
              result = denied;
            } else if (exec == null) {
              result = ToolResult(
                  callId: call.id,
                  toolName: call.name,
                  ok: false,
                  content: 'no executor for ${call.name}',
                  meta: {'error': 'no-executor'});
            } else {
              try {
                final content = await exec(call.arguments);
                var ok = ToolResult(
                    callId: call.id,
                    toolName: call.name,
                    ok: true,
                    content: content);
                for (final p in _inOrder()) {
                  final replacement = _runHook(
                      () => p.afterTool(_snap(pinned), ok)) as ToolResult?;
                  if (replacement != null) ok = replacement.snapshot();
                }
                result = ok;
              } catch (e) {
                result = ToolResult(
                    callId: call.id,
                    toolName: call.name,
                    ok: false,
                    content: 'tool threw: $e',
                    meta: {'error': 'threw'});
              }
            }
          }
        }

        // Step 5: append the result. Pairing holds even for a cancelled,
        // denied or skipped call: the core writes a result that says so.
        final message = Message.toolResult(result);
        _transcript.add(message);
        appended.add(message);
      }

      // The pinning invariant: the live tool set still matches the pinned
      // set. A plugin that left is not a change — its tools became
      // undispatchable, which the liveness check handled. Anything else is.
      final livePinned = {
        for (final name in pinnedMap.keys)
          if (_byId.containsKey(ownerOf[name]!)) name
      };
      final now = {
        for (final p in _inOrder())
          for (final t in p.tools) t.name
      };
      if (now.length != livePinned.length || !now.containsAll(livePinned)) {
        return finish(StopReason.error, 'tools-changed mid-turn');
      }
    }
    return finish(StopReason.error, 'max-steps ($maxStepsPerTurn) exceeded');
  }
}
