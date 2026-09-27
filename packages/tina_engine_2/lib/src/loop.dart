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
/// Plugins own decisions, made by writing to the [TurnContext] they are
/// handed — the loop copies the context before every plugin call, hands
/// the copy over, and keeps the copy the call wrote, so a plugin that
/// throws has its writes dropped and the turn continues. Registration,
/// snapshots, the prompt join, pinning, dispatch and turn bookkeeping all
/// live here — each is a few lines, and pulling any of them out would make
/// a reader jump between files to follow one turn.
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

  /// Give a tool its executor. Executors are not part of [ToolSchema]: they
  /// run in-process and return the full [ToolResult] — content plus flags —
  /// and `afterToolResult` can replace what they returned. An existing
  /// string-returning function wraps with [stringExecutor].
  void registerExecutor(
      String tool, Future<ToolResult> Function(Map<String, Object?>) exec) {
    _executors[tool] = exec;
  }

  final Map<String, Future<ToolResult> Function(Map<String, Object?>)>
      _executors = {};

  /// The one cancellation path.
  void cancel(String why) => _cancel.cancel(why);

  /// The transcript so far — the loop's truth. Read-only view.
  Iterable<Message> get transcript => List.unmodifiable(_transcript);

  /// The fresh context a turn starts from: the input as it arrived, the
  /// transcript so far, no sections yet, the pinned tools.
  TurnContext _start(Input raw, List<ToolSchema> pinned) => TurnContext(
        _cancel,
        input: raw,
        messages: List.of(_transcript),
        promptSections: const [],
        pinnedTools: List.of(pinned),
      );

  /// One plugin phase. The copy rule lives here, in one place: each plugin
  /// is handed a copy of the *current* state, and the copy it wrote is
  /// kept. A plugin that throws has its copy dropped — its writes never
  /// arrive, and the next plugin still runs. The loop holds the before and
  /// the after of every call (here, `ctx` and `copy`), which is what a
  /// later slice records; nothing records it yet.
  TurnContext _phase(
      TurnContext ctx, void Function(AgentPlugin p, TurnContext c) body) {
    for (final p in _inOrder()) {
      final copy = ctx.copy();
      try {
        body(p, copy);
      } catch (_) {
        continue; // one bad plugin must not break the turn
      }
      ctx = copy;
    }
    return ctx;
  }

  /// The system prompt: the context's sections joined by a blank line, in
  /// the order they were added. A plugin adds one section, never a whole
  /// prompt; an empty section contributes nothing. With no sections the
  /// prompt is an empty string — the core owns no prompt text.
  static String _joinSections(List<String> sections) => [
        for (final s in sections)
          if (s.isNotEmpty) s,
      ].join('\n\n');

  /// The five steps of one turn, in order, in one pass.
  Future<Outcome> runTurn(Input raw) async {
    // ------------------------------------------------------------------
    // Step 1: take the input. The pinned tool set is snapshotted once,
    // from the plugins' `tools` getters, before anything runs.
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

    var ctx = _start(raw, pinned);

    // The single exit: build the outcome, fan out onTurnEnd, return.
    // A throwing plugin is isolated by the phase helper; the others still
    // get the outcome.
    Outcome finish(StopReason reason, String detail) {
      final outcome = Outcome(
          stopReason: reason,
          messages: List.of(appended),
          modelRequests: [for (final r in requests) r.snapshot()],
          modelResponses: List.of(responses),
          usage: responses.length,
          detail: detail,
          changedBy: changedBy);
      _phase(ctx, (p, c) {
        c.outcome = outcome;
        p.onTurnEnd(c);
      });
      return outcome;
    }

    // Prompt-section phase, once per turn. The sections the plugins add
    // here are the base; `beforeModelCall` may adjust them per call.
    ctx = _phase(ctx, (p, c) => p.onPrompt(c));
    final baseSections = List.of(ctx.promptSections);

    // Input phase. A rewrite is an assignment to `c.input`; the last
    // rewrite is the one the outcome records.
    for (final p in _inOrder()) {
      final before = ctx.input;
      final copy = ctx.copy();
      try {
        p.onInput(copy);
      } catch (_) {
        continue; // one bad plugin must not break the turn
      }
      ctx = copy;
      if (ctx.input.text != before.text || ctx.input.id != before.id) {
        changedBy = p.id;
      }
    }
    final user = Message(
        role: Role.user, content: [TextBlock(ctx.input.text)]);
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

      // Step 2: build the request. The context is refreshed from the
      // loop's own truth — the transcript and the turn's base sections —
      // then the per-call phase runs, and the request is built from what
      // the context holds afterwards. A plugin that prunes or redacts
      // prunes this request, never the transcript.
      ctx
        ..messages = List.of(_transcript)
        ..promptSections = List.of(baseSections)
        ..call = null
        ..toolResult = null
        ..decision = const Decision.allow();
      ctx = _phase(ctx, (p, c) => p.beforeModelCall(c));
      var request = Request(
          systemPrompt: _joinSections(ctx.promptSections),
          messages: List.of(ctx.messages),
          tools: List.of(ctx.pinnedTools));

      // Step 3: call the model. The provider streams: [ToolCallStart]
      // announces each call the model asks for, the text deltas accumulate
      // the answer, and [MessageComplete] carries the final blocks — the
      // tool-use inputs come from there, keyed by the started ids. A
      // [StreamError] ends the turn as StopReason.error, recorded. A
      // provider that throws — at `send` or anywhere in the stream — is
      // caught here: the turn ends the same way, and whatever deltas had
      // already accumulated are kept as the reply, not discarded.
      final starts = <ToolCallStart>[];
      final blocksById = <String, ToolUseBlock>{};
      final deltaText = StringBuffer();
      MessageComplete? completion;
      StreamError? failure;
      Object? thrown;
      try {
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
      } catch (e) {
        thrown = e; // the turn ends below, at the single StreamError exit
      }
      if (failure != null) {
        return finish(StopReason.error, 'provider error: ${failure.error}');
      }
      if (thrown != null) {
        if (deltaText.isNotEmpty) {
          // Keep the partial text the model managed to stream.
          final partial = Message(
              role: Role.assistant,
              content: [TextBlock(deltaText.toString())]);
          requests.add(request.snapshot());
          _transcript.add(partial);
          appended.add(partial);
          responses.add(partial);
        }
        return finish(StopReason.error, 'provider error: $thrown');
      }
      // A call announced by [ToolCallStart] whose block never arrived via
      // [MessageComplete] has no [ToolUseBlock] in the transcript: there
      // is no tool_use to pair a result with, and nothing legitimate to
      // dispatch. Dispatching it would fabricate an empty-input call and a
      // successful result for a tool_use that does not exist, and the
      // assistant reply would be an empty message. So — no dispatch, no
      // result, no reply message; the turn ends with the reason recorded.
      // The pairing invariant is untouched: this case creates neither
      // side of the pair.
      final orphans = [
        for (final s in starts) if (!blocksById.containsKey(s.id)) s
      ];
      if (orphans.isNotEmpty) {
        return finish(
            StopReason.error,
            'provider stream ended before tool call '
            '${[for (final s in orphans) s.id].join(', ')} completed');
      }
      final blocks = completion?.content ??
          [if (deltaText.isNotEmpty) TextBlock(deltaText.toString())];
      final toolCalls = [
        for (final s in starts)
          ToolUse(id: s.id, name: s.name, input: blocksById[s.id]!.input),
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
      // mid-turn has its call skipped, not crashed on. Then the guard
      // phase, in order — the first non-allow decision stops the phase and
      // the call is not dispatched (`ask` with no UI resolves to deny).
      // Then the executor; then the result phase, in order, which may
      // replace the result the core records. Attribution (who denied, why)
      // travels in the result's content: the model reads exactly this
      // string.
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
            ctx
              ..call = call
              ..decision = const Decision.allow();
            String? deniedBy;
            for (final p in _inOrder()) {
              final copy = ctx.copy();
              try {
                p.beforeToolCall(copy);
              } catch (_) {
                continue; // a throwing guard allows, like any absent one
              }
              ctx = copy;
              if (ctx.decision.kind != DecisionKind.allow) {
                deniedBy = p.id; // first non-allow decides; later guards
                break; // do not run
              }
            }
            final decision = ctx.decision;
            final exec = _executors[call.name];
            if (deniedBy != null) {
              result = decision.replacement ??
                  ToolResult(
                      'denied by $deniedBy'
                      '${decision.kind == DecisionKind.ask ? ' (ask-unresolved)' : ''}'
                      ': ${decision.reason}',
                      isError: true);
            } else if (exec == null) {
              result = ToolResult('no executor for ${call.name}',
                  isError: true);
            } else {
              try {
                var recorded = await exec(call.input);
                ctx.toolResult = recorded;
                ctx = _phase(ctx, (p, c) => p.afterToolResult(c));
                recorded = ctx.toolResult ?? recorded;
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
