import 'dart:async';

import 'package:logging/logging.dart';

import '../llm/message.dart';
import '../llm/provider.dart';
import '../permissions/policy.dart';
import '../permissions/prompt.dart';
import '../tools/tool.dart';
import '../host/host_interface.dart';
import 'agent_sink.dart';
import 'pause_gate.dart';
import 'stream_consumer.dart';
import 'token_budget.dart';

final _log = Logger('tina.agent');

/// Hard-coded ceiling on tool invocations per turn. The run loop bounds *steps*
/// via [Agent.maxSteps] but not *tool uses* — this is the coarse backstop that
/// complements the token spend-funnel (~10× maxSteps=50, so legitimate
/// multi-file refactors have headroom; tool uses are serial per step). When
/// tripped the turn stops with a notice. `--yolo` can't extend it (it only
/// relaxes the ask-gate). No config surface by design.
const int kMaxToolCallsPerRun = 500;

/// Why a turn stopped abnormally, classified by cause. Callers that decide
/// whether to retry (e.g. the pipeline's codergen nodes) treat [provider]
/// failures as transient — a rate limit or dropped stream may clear on its
/// own — while [budget]/[steps] exhaustions and [cancel] never will.
enum AbortedKind { none, provider, budget, steps, cancel }

const _compactSystemPrompt = '''
You are summarizing a coding-assistant conversation for context
preservation. Output ONLY the summary — no preamble, no closing.
Use terse markdown bullets, <= 400 words. Preserve:
- file paths the user or assistant referenced or edited
- decisions taken and the reason behind them
- unresolved questions or pending work
- errors encountered and how they were resolved
Omit pleasantries and reasoning that did not lead anywhere.
''';

class Agent {
  LlmProvider _provider;

  /// The provider this agent sends requests to. Mutable so `/model` can swap
  /// the provider instance at runtime — the agent re-reads it on each [run].
  LlmProvider get provider => _provider;
  set provider(LlmProvider value) => _provider = value;
  final ToolRegistry tools;
  final AgentSink sink;
  final PermissionPolicy policy;
  final PermissionAsker asker;
  final int maxSteps;

  /// Per-turn / per-session token caps. An immutable value: each
  /// `record` / `resetTurn` / `resetSession` returns a new [TokenBudget] and
  /// we reassign this field to it. So read live totals through `budget` here,
  /// not a reference captured before the turn (a captured one goes stale).
  TokenBudget? budget;

  /// When set, a per-session budget trip pauses ALL agents and asks the user
  /// (continue/abort) instead of hard-aborting the turn. Null in headless /
  /// tests that want the legacy abort behavior.
  final PauseGate? pauseGate;

  /// Resolved once at construction; reused for every provider call so the
  /// system prefix stays stable across a multi-step turn (cache-friendly).
  final String system;

  Agent({
    required LlmProvider provider,
    required this.tools,
    required this.sink,
    required this.policy,
    required this.asker,
    this.maxSteps = 50,
    this.budget,
    this.pauseGate,
    required this.system,
  }) : _provider = provider;

  /// Run one user turn. The agent may issue several provider calls if tools
  /// are invoked. [cancelSignal], when completed, aborts the current
  /// in-flight stream and exits the turn cleanly.
  /// Why the previous turn stopped, when it stopped abnormally — a budget
  /// trip, a provider/API error (remote rate limit, insufficient funds, auth),
  /// a cut-off stream, the action cap, or max steps. null after a normal
  /// finish (or a cancel). Reset at the top of every [run]. The interactive
  /// controller persists this as a synthetic assistant message so a restored
  /// session still shows why the turn died; it is never appended to history
  /// here, so the scheduler's result extraction can't mistake it for a real
  /// answer.
  String? abortedReason;

  /// The same stop classified by cause, for callers deciding whether a retry
  /// could succeed: [AbortedKind.provider] failures (rate limit, dropped
  /// stream, transient build failure) may clear on their own; budget/steps
  /// exhaustions and cancellations will not. Reset alongside [abortedReason].
  AbortedKind abortedKind = AbortedKind.none;

  /// Run one user turn. The agent may issue several provider calls if tools
  /// are invoked. [cancelSignal], when completed, aborts the current
  /// in-flight stream and exits the turn cleanly.
  ///
  /// The activity lifecycle is owned HERE, not by each caller: when the sink
  /// is a full host ([HostInterface]), the run raises its activity signal on
  /// entry and clears it on every exit path — the turn-in-flight semantics of
  /// HostInterface.setActivity (tin-y4qn). Callers that wrap a run with extra
  /// scope (the scheduler's job-level signal for panelized delegation, the
  /// environment ceremony's survey phase) may signal too; hosts treat repeats
  /// as idempotent. A sink that is only an [AgentSink] (telemetry sinks, the
  /// headless no-op) has no signal to drive and skips this.
  Future<void> run({
    required List<Message> history,
    required String userInput,
    Future<void>? cancelSignal,
  }) async {
    final HostInterface? activityHost =
        sink is HostInterface ? sink as HostInterface : null;
    activityHost?.setActivity(true);
    try {
      await _runTurn(
        history: history,
        userInput: userInput,
        cancelSignal: cancelSignal,
      );
    } finally {
      activityHost?.setActivity(false);
    }
  }

  Future<void> _runTurn({
    required List<Message> history,
    required String userInput,
    Future<void>? cancelSignal,
  }) async {
    abortedReason = null;
    abortedKind = AbortedKind.none;
    history.add(Message(role: Role.user, content: [TextBlock(userInput)]));

    var cancelled = false;
    cancelSignal?.then((_) => cancelled = true);
    budget = budget?.resetTurn();

    // Action cap: count tool invocations across all steps of this turn. A step
    // may issue many tool calls; this coarse backstop (complementing the token
    // funnel + maxSteps) bounds the total so a runaway loop can't run forever.
    // --yolo can't extend it. Tripping stops the turn with a notice.
    var toolCalls = 0;

    for (var step = 0; step < maxSteps; step++) {
      if (cancelled) {
        sink.notice('\n[cancelled]\n', kind: NoticeKind.warning);
        abortedKind = AbortedKind.cancel;
        return;
      }

      // Pre-flight: refuse a request whose input alone would blow past the
      // per-request cap. Catches the "single tool returned 5MB of context"
      // scenario before we put it on the wire.
      final reject =
          budget?.checkRequestInput(system, history, tools.schemas);
      if (reject != null) {
        sink.notice('\n[budget] $reject\n', kind: NoticeKind.error);
        abortedReason = reject;
        abortedKind = AbortedKind.budget;
        return;
      }

      final stream = provider.send(
        system: system,
        messages: history,
        tools: tools.schemas,
      );
      final outcome = await const ProviderStreamConsumer()
          .consume(stream, sink: sink, cancelSignal: cancelSignal);
      if (outcome.error != null) {
        sink.notice('\nerror: ${outcome.error}\n', kind: NoticeKind.error);
        abortedReason = outcome.error.toString();
        abortedKind = AbortedKind.provider;
        return;
      }
      if (outcome.cancelled) {
        // [cancelled] notice already printed by ProviderStreamConsumer before
        // the async stream teardown, so it appears in the panel immediately.
        return;
      }
      final content = outcome.content;
      if (content == null) {
        // Stream closed without ever yielding MessageComplete — server cut
        // us off mid-response, or the SSE framing was broken. Don't crash
        // on a null-assert; surface it and let the user retry.
        sink.notice('\nerror: stream ended without a complete response\n',
            kind: NoticeKind.error);
        abortedReason = 'stream ended without a complete response';
        abortedKind = AbortedKind.provider;
        return;
      }
      if (outcome.usage != null) {
        budget = budget?.record(outcome.usage!);
        final kind = budget?.exceededLimit();
        if (kind != null) {
          if (pauseGate != null && kind == TokenLimitKind.perSession) {
            // Per-session trip: pause ALL agents and ask the user. The tripped
            // response wasn't appended to history yet (that's below), so after
            // a reset the loop re-sends cleanly. Both Continue and Abort reset
            // this agent's session counter (Abort otherwise re-trips on the
            // very next turn); the decision only changes whether this turn
            // resumes or aborts.
            pauseGate!.requestPause(budget!.exceeded()!);
            final cont =
                await pauseGate!.waitForResume(cancelSignal: cancelSignal);
            budget = budget?.resetSession();
            if (!cont) {
              sink.notice('\n[budget] session limit — turn aborted\n',
                  kind: NoticeKind.warning);
              abortedReason = 'session limit — turn aborted';
              abortedKind = AbortedKind.budget;
              return;
            }
            continue; // resume the loop; next iteration re-sends the request
          }
          sink.notice('\n[budget] ${budget!.exceeded()}\n',
              kind: NoticeKind.error);
          abortedReason = budget!.exceeded();
          abortedKind = AbortedKind.budget;
          return;
        }
      }

      history.add(Message(role: Role.assistant, content: content));

      final toolUses = content.whereType<ToolUseBlock>().toList();
      if (toolUses.isEmpty) {
        return;
      }

      final results = <ContentBlock>[];
      for (final use in toolUses) {
        if (cancelled) break;
        if (toolCalls >= kMaxToolCallsPerRun) {
          sink.notice('\n[action limit] reached, stopping\n',
              kind: NoticeKind.warning);
          abortedReason = 'action limit reached, stopping';
          abortedKind = AbortedKind.steps;
          return;
        }
        toolCalls++;
        // The model's tool-call arguments were not valid JSON (tin-p2sq: a
        // quote-heavy shell one-liner it failed to escape). The tool cannot
        // run, but the turn need not die: answer the call with an error the
        // model can act on, and let the next step re-emit it correctly.
        final parseError = use.argumentsParseError;
        if (parseError != null) {
          sink.notice(
              '  ${use.name}: malformed arguments — asking the model to '
              'retry\n',
              kind: NoticeKind.warning);
          results.add(ToolResultBlock(
            toolUseId: use.id,
            content: 'Your ${use.name} call was discarded: its arguments '
                'were not valid JSON ($parseError). This usually means '
                'quotes or backslashes in the command text were not escaped '
                'for JSON — re-emit the call with '
                r'inner double quotes written as \" and each literal '
                r'backslash as \\.',
            isError: true,
          ));
          continue;
        }
        final tool = tools[use.name];
        if (tool == null) {
          sink.notice('  unknown tool: ${use.name}\n', kind: NoticeKind.error);
          results.add(ToolResultBlock(
            toolUseId: use.id,
            content: 'Unknown tool: ${use.name}',
            isError: true,
          ));
          continue;
        }

        var decision = policy.check(use.name, use.input);
        if (decision == PermissionDecision.ask) {
          final prompt = PermissionPrompt(use.name, use.input);
          final resp = await asker(prompt);
          decision = resp.decision;
          if (resp.remember) {
            policy.remember(use.name, prompt.alwaysPattern, decision);
          }
        }
        if (decision == PermissionDecision.deny) {
          sink.notice('  ${use.name} denied\n');
          results.add(ToolResultBlock(
            toolUseId: use.id,
            content: 'Denied by permission policy.',
            isError: true,
          ));
          continue;
        }

        sink.toolStart(ToolStartEvent(use.name, use.id, use.input));
        try {
          final out = await tool.execute(
            use.input,
            cancelSignal: cancelSignal,
            onOutput: (chunk, {bool stderr = false}) {
              sink.toolOutput(
                  ToolOutputEvent(use.name, use.id, chunk, stderr: stderr));
            },
          );
          sink.toolComplete(ToolCompleteEvent(use.name, use.id,
              isError: out.isError, result: out.content));
          results.add(ToolResultBlock(
            toolUseId: use.id,
            content: out.content,
            isError: out.isError,
          ));
        } catch (e, st) {
          // Route thrown-tool failures through the same toolComplete path so
          // a tool strip / observer learns about them too. (Previously this
          // printed the bare exception; it now renders like an error result.)
          _log.severe('unhandled exception in tool ${use.name}', e, st);
          sink.toolComplete(ToolCompleteEvent(use.name, use.id,
              isError: true, result: e.toString()));
          results.add(ToolResultBlock(
            toolUseId: use.id,
            content: e.toString(),
            isError: true,
          ));
        }
      }
      history.add(Message(role: Role.user, content: results));
    }

    sink.notice('(max steps reached)\n', kind: NoticeKind.warning);
    abortedReason = 'max steps reached';
    abortedKind = AbortedKind.steps;
  }

  /// Replace (part of) [history] with a summarized user+assistant exchange.
  /// Streams the summary so the user can see what was kept; on failure the
  /// original history is left untouched. Returns true if the history was
  /// actually compacted, false if it was skipped (empty, too little to
  /// summarize, or the summary failed).
  ///
  /// [preserveRecent] (default 0) keeps the most recent turns intact and
  /// summarizes only the older prefix. It counts *human turns* (user messages
  /// carrying text, not tool-result messages), and the split always lands on a
  /// human-turn boundary — never between a tool_use and its tool_result — so the
  /// preserved suffix stays a valid conversation the provider will accept. 0
  /// summarizes the whole history (the `/compact` behavior).
  Future<bool> compact(List<Message> history, {int preserveRecent = 0}) async {
    if (history.isEmpty) {
      sink.notice('(nothing to compact)\n');
      return false;
    }

    final List<Message> prefix;
    final List<Message> suffix;
    if (preserveRecent <= 0) {
      prefix = history;
      suffix = const [];
    } else {
      final split = _recentHumanTurnBoundary(history, preserveRecent);
      if (split <= 0) return false; // fewer recent human turns than requested
      prefix = history.sublist(0, split);
      suffix = history.sublist(split);
      if (prefix.length < 2) return false; // not enough older context to summarize
    }

    final priorCount = history.length;
    final summaryRequest = [
      ...prefix,
      const Message(role: Role.user, content: [
        TextBlock('Summarize the conversation above following the system instructions.'),
      ]),
    ];

    sink.notice(preserveRecent > 0
        ? '--- compacting $priorCount messages (keeping ${suffix.length} recent) ---\n'
        : '--- compacting $priorCount messages ---\n');

    final stream = provider.send(
      system: _compactSystemPrompt,
      messages: summaryRequest,
      tools: const [],
    );

    final buf = StringBuffer();
    final done = Completer<void>();
    Object? err;
    var sawText = false;

    // compact uses a simpler listen than ProviderStreamConsumer because it
    // only needs text deltas — no tool calls or usage tracking.
    stream.listen(
      (event) {
        if (event is TextDelta) {
          if (!sawText) {
            sink.activityStop();
            sawText = true;
          }
          sink.text(event.text);
          buf.write(event.text);
        } else if (event is StreamError) {
          err = event.error;
        }
      },
      onDone: () {
        sink.activityStop();
        if (sawText) sink.newline();
        if (!done.isCompleted) done.complete();
      },
      onError: (Object e) {
        sink.activityStop();
        err = e;
        if (!done.isCompleted) done.complete();
      },
    );

    await done.future;

    if (err != null) {
      sink.notice('compact failed: $err\n', kind: NoticeKind.error);
      return false;
    }
    final summary = buf.toString().trim();
    if (summary.isEmpty) {
      sink.notice('compact failed: empty summary\n', kind: NoticeKind.error);
      return false;
    }

    history
      ..clear()
      ..add(Message(
        role: Role.user,
        content: [TextBlock('Prior conversation summary:\n\n$summary')],
      ))
      ..add(const Message(
        role: Role.assistant,
        content: [TextBlock('Got it — continuing from this summary.')],
      ))
      ..addAll(suffix);
    final after = 2 + suffix.length;
    sink.notice('--- compacted $priorCount → $after messages ---\n');
    return true;
  }

  /// Index in [history] of the [keep]-th-most-recent *human* turn (a user
  /// message carrying a [TextBlock], not a tool-result message), so [compact]
  /// can split the history there. Cutting at a human-turn boundary never severs
  /// a tool_use/tool_result pair — those are an assistant→user(toolresult)
  /// sequence, a different user-message shape. Returns 0 if there are fewer than
  /// [keep] human turns (nothing to split off as a prefix).
  static int _recentHumanTurnBoundary(List<Message> history, int keep) {
    var humanTurns = 0;
    for (var i = history.length - 1; i >= 0; i--) {
      final m = history[i];
      if (m.role == Role.user && m.content.any((b) => b is TextBlock)) {
        humanTurns++;
        if (humanTurns == keep) return i;
      }
    }
    return 0;
  }

}
