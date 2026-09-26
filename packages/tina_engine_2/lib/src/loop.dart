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
///
/// Value types (Message, ToolSchema, ToolUse, ToolResult, stream events)
/// come from `tina_core`; the model boundary is its streaming
/// `LlmProvider.send`.
library;

import 'dart:collection';

import 'package:tina_core/tina_core.dart';

import 'context.dart';
import 'model.dart';
import 'plugin.dart';

/// The agent loop.
final class AgentLoop {
  AgentLoop({
    required LlmProvider provider,
    required List<AgentPlugin> plugins,
    this.maxStepsPerTurn = 16,
  }) : _provider = provider {
    for (final p in plugins) {
      addPlugin(p);
    }
  }

  final LlmProvider _provider;
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

  /// Give a tool its executor. Executors are not part of [ToolSchema].
  void registerExecutor(
          String tool, Future<String> Function(Map<String, Object?>) exec) =>
      _executors[tool] = exec;
  final Map<String, Future<String> Function(Map<String, Object?>)> _executors =
      {};

  /// The one cancellation path.
  void cancel(String why) => _cancel.cancel(why);

  /// What a hook run hands the plugin: the shared cancel path.
  Context _snap() => Context(_cancel);

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
  String _prompt(List<ToolSchema> pinned,
      {String header = 'You are tina, a terminal coding agent.'}) {
    final sections = <String>[header];
    for (final p in _inOrder()) {
      try {
        final section = p.systemSection(_snap());
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
          messages: List.of(appended),
          modelRequests: [for (final r in requests) r.snapshot()],
          modelResponses: List.of(responses),
          usage: responses.length,
          detail: detail,
          changedBy: changedBy);
      for (final p in _inOrder()) {
        try {
          p.onTurnEnd(_snap(), outcome);
        } catch (_) {
          // one bad plugin must not break the turn end
        }
      }
      return outcome;
    }

    var input = raw;
    for (final p in _inOrder()) {
      final replacement =
          _runHook(() => p.beforeInvocation(_snap(), input));
      if (replacement != null) {
        input = replacement;
        changedBy = p.id; // the last rewrite is recorded
      }
    }
    final user = Message(role: Role.user, content: [TextBlock(input.text)]);
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
          tools: List.of(pinned));
      for (final p in _inOrder()) {
        final replacement = _runHook(
            () => p.beforeRequest(_snap(), request.snapshot()));
        if (replacement != null) request = replacement;
      }

      // Step 3: call the model. The provider streams: [ToolCallStart]
      // announces each call the model asks for, the text deltas accumulate
      // the answer, and [MessageComplete] carries the final blocks — the
      // tool-use inputs come from there, keyed by the started ids. A
      // [StreamError] ends the turn as StopReason.error, recorded.
      final starts = <ToolCallStart>[];
      final blocksById = <String, ToolUseBlock>{};
      final deltaText = StringBuffer();
      MessageComplete? completion;
      StreamError? failure;
      await for (final event in _provider.send(
          system: request.systemPrompt,
          messages: request.messages,
          tools: request.tools)) {
        if (event is ToolCallStart) {
          starts.add(event);
        } else if (event is TextDelta) {
          deltaText.write(event.text);
        } else if (event is MessageComplete) {
          completion = event;
          for (final b in event.content.whereType<ToolUseBlock>()) {
            blocksById[b.id] = b;
          }
        } else if (event is StreamError) {
          failure = event;
          break;
        }
        // Reasoning deltas and stream notices carry no transcript state.
      }
      if (failure != null) {
        return finish(StopReason.error, 'provider error: ${failure.error}');
      }
      final blocks = completion?.content ??
          [if (deltaText.isNotEmpty) TextBlock(deltaText.toString())];
      final toolCalls = [
        for (final s in starts)
          ToolUse(
              id: s.id,
              name: s.name,
              input: blocksById[s.id]?.input ?? const {}),
      ];
      final replyText = [
        for (final b in blocks.whereType<TextBlock>()) b.text
      ].join();
      requests.add(request.snapshot());
      final reply = Message(role: Role.assistant, content: blocks);
      _transcript.add(reply);
      appended.add(reply);
      responses.add(reply);
      if (toolCalls.isEmpty) {
        return finish(StopReason.complete, replyText);
      }

      // Step 4: run the tool calls. Liveness first: a plugin that left
      // mid-turn has its call skipped, not crashed on. Then guards, in
      // order — all must pass; `ask` with no UI resolves to deny. Then
      // the executor; then `afterTool`, in order, which may replace the
      // result the core records. Attribution (who denied, why) travels in
      // the result's content: the model reads exactly this string.
      for (final call in toolCalls) {
        ToolResult result;
        if (_cancel.cancelled) {
          result = ToolResult('cancelled: ${_cancel.reason}', isError: true);
        } else {
          final owner = ownerOf[call.name];
          if (owner != null && !_byId.containsKey(owner)) {
            result =
                ToolResult('skipped: plugin $owner left', isError: true);
          } else {
            ToolResult? denied;
            for (final p in _inOrder()) {
              final decision =
                      _runHook(() => p.beforeTool(_snap(), call)) ??
                  const Decision.allow();
              if (decision.kind != DecisionKind.allow) {
                denied = decision.replacement ??
                    ToolResult(
                        'denied by ${p.id}'
                        '${decision.kind == DecisionKind.ask ? ' (ask-unresolved)' : ''}'
                        ': ${decision.reason}',
                        isError: true);
                break;
              }
            }
            final exec = _executors[call.name];
            if (denied != null) {
              result = denied;
            } else if (exec == null) {
              result = ToolResult('no executor for ${call.name}',
                  isError: true);
            } else {
              try {
                final content = await exec(call.input);
                var recorded = ToolResult(content);
                for (final p in _inOrder()) {
                  final replacement = _runHook(
                      () => p.afterTool(_snap(), recorded)) as ToolResult?;
                  if (replacement != null) recorded = replacement;
                }
                result = recorded;
              } catch (e) {
                result = ToolResult('tool threw: $e', isError: true);
              }
            }
          }
        }

        // Step 5: append the result. Pairing holds even for a cancelled,
        // denied or skipped call: the core writes a result that says so.
        final message = Message(
            role: Role.user,
            content: [
              ToolResultBlock(
                  toolUseId: call.id,
                  content: result.content,
                  isError: result.isError),
            ]);
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
