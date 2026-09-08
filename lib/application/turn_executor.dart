import 'dart:async';
import 'package:tina_engine/tina_engine.dart';
import '../conversation.dart';
import '../pipeline/workflow_supervisor.dart';
import '../platform/environment.dart';

enum TurnState { idle, running, cancelling, closed }

enum TurnSubmission { started, queued, rejected }

class _TurnSlot {
  final Conversation conversation;
  final Completer<void> idle = Completer<void>();
  TurnState state = TurnState.running;
  _TurnSlot(this.conversation);
}

/// Sole admission/drain owner. A cancellation request does not release a slot.
class TurnExecutor {
  final Conversation? Function(String id) findConversation;
  final Future<void> Function(Conversation conversation)? persistUsage;
  final void Function()? onChanged;
  final Environment environment;
  int autoCompactThreshold;
  final int autoCompactPreserveRecent;
  final _slots = <String, _TurnSlot>{};
  final _closed = <String>{};
  bool _closing = false;
  Future<void>? _shutdown;
  TurnExecutor({
    required this.findConversation,
    this.persistUsage,
    this.onChanged,
    this.environment = const PlatformEnvironment(),
    this.autoCompactThreshold = 0,
    this.autoCompactPreserveRecent = 2,
  });

  TurnState state(String id) {
    final conversation = _slots[id]?.conversation ?? findConversation(id);
    if (_closing ||
        _closed.contains(id) ||
        conversation == null ||
        conversation.isClosed) {
      return TurnState.closed;
    }
    return _slots[id]?.state ?? TurnState.idle;
  }

  TurnSubmission submit(String id, String prompt) {
    final conversation = findConversation(id);
    if (_closing ||
        _closed.contains(id) ||
        conversation == null ||
        conversation.isClosed) {
      return TurnSubmission.rejected;
    }
    if (_slots.containsKey(id)) {
      conversation.messageQueue.enqueue(prompt);
      return TurnSubmission.queued;
    }
    final slot = _TurnSlot(conversation);
    _slots[id] = slot;
    conversation.turnCompletion = slot.idle.future;
    unawaited(_drain(slot, prompt));
    return TurnSubmission.started;
  }

  bool cancel(String id) {
    final slot = _slots[id];
    if (slot == null) return false;
    slot.state = TurnState.cancelling;
    final cancel = slot.conversation.cancelCompleter;
    if (cancel != null && !cancel.isCompleted) cancel.complete();
    return true;
  }

  bool interruptTools(String id) {
    final slot = _slots[id];
    if (slot == null || slot.conversation.messageQueue.isEmpty) return false;
    final interrupt = slot.conversation.toolInterruptCompleter;
    if (interrupt == null || interrupt.isCompleted) return false;
    interrupt.complete();
    return true;
  }

  void injectWorkflowResult(WorkflowRun run) {
    if (run.status == WorkflowRunStatus.cancelled) return;
    final result = submit(run.conversationId, _workflowOutcomePrompt(run));
    if (result == TurnSubmission.queued) {
      try {
        findConversation(run.conversationId)?.host.showMessage(
          '[workflow "${run.workflowName}" finished — result queued]\n',
          style: HostMessageStyle.dim,
        );
      } catch (_) {}
    }
  }

  Future<void> whenIdle(String id) => _slots[id]?.idle.future ?? Future.value();
  Future<void> close(String id) {
    _closed.add(id);
    final c = findConversation(id);
    c?.beginClose();
    cancel(id);
    return whenIdle(id);
  }

  Future<void> shutdown() => _shutdown ??= _stop();
  Future<void> _stop() async {
    _closing = true;
    final slots = _slots.values.toList();
    for (final slot in slots) {
      close(slot.conversation.id);
    }
    await Future.wait(slots.map((s) => s.idle.future));
  }

  void _changed() {
    try {
      onChanged?.call();
    } catch (_) {}
  }

  Future<void> _drain(_TurnSlot slot, String first) async {
    final s = slot.conversation;
    String? next = first;
    try {
      while (next != null &&
          !_closing &&
          !s.isClosed &&
          !_closed.contains(s.id) &&
          identical(findConversation(s.id), s)) {
        slot.state = TurnState.running;
        s.cancelCompleter = Completer<void>();
        s.toolInterruptCompleter = Completer<void>();
        final activity = RunActivity(s.host);
        _changed();
        try {
          await _runTurn(s, next);
        } catch (_) {
          // Cosmetic host failures must not strand admission or shutdown.
        } finally {
          activity.complete();
          try {
            await persistUsage?.call(s);
          } catch (_) {}
        }
        next = s.messageQueue.dequeue();
      }
    } finally {
      s.cancelCompleter = null;
      s.toolInterruptCompleter = null;
      s.turnCompletion = null;
      _slots.remove(s.id);
      if (s.isClosed || _closing) s.messageQueue.clear();
      slot.idle.complete();
      _changed();
    }
  }

  Future<void> _runTurn(Conversation s, String input) async {
    final cancel = s.cancelCompleter!;
    final toolInterrupt = s.toolInterruptCompleter!;
    s.host.showSeparator();
    s.host.showMessage('$input\n', style: HostMessageStyle.user);
    s.host.showSeparator();

    // Auto-compact before the turn if the about-to-be-sent request is large.
    // Runs before preLen is captured so the new turn's messages are all that's
    // appended on completion (the summary itself is persisted via replace).
    // Compact failure must not strand the markers armed above: the failure
    // completes the cancel completer, so the turn unwinds through the cancel
    // path (rollback + queue survival) instead of hanging busy.
    if (autoCompactThreshold > 0) {
      try {
        await _maybeAutoCompact(s, input);
      } catch (e, st) {
        s.host.showMessage('error: $e\n', style: HostMessageStyle.error);
        if (environment.env['COCOON_DEBUG'] == '1') {
          s.host.showMessage('$st\n', style: HostMessageStyle.dim);
        }
        if (!cancel.isCompleted) cancel.complete();
      }
    }

    // Turn-scope state the unwind below needs on every path — including the
    // ESC-won skip, where the run never started and history is unchanged
    // (rollback then removes nothing).
    final preLen = s.history.length;
    final rec = s.recorder;

    // An Esc-Esc that landed while the pre-turn awaits were in flight (the
    // user-message persist below, or a compaction) wins before the run
    // starts: skip the doomed run and unwind through the cancel path.
    if (!cancel.isCompleted) {
      // Persist the user's message BEFORE the turn starts, so it survives a
      // quit before the response completes and is restored by `-c`. `agent.run`
      // adds the same message to in-memory history; the post-turn append below
      // skips it, and a cancel rolls it back via replace — so cancel still
      // discards the whole exchange, but a process killed mid-stream no longer
      // loses the prompt.
      final userMessage = Message(role: Role.user, content: [TextBlock(input)]);
      if (rec != null) {
        try {
          await rec.append(userMessage);
        } catch (e) {
          s.host.showMessage(
            'session write failed: $e\n',
            style: HostMessageStyle.error,
          );
        }
      }

      // Normal turns run the plain agent. A workflow is launched on demand by
      // the agent itself via its `launch_workflow` tool (the supervisor seam
      // wired by the coordinator) — a fire-and-forget call: the run churns in
      // the background while the chat stays open, and its completion injects a
      // follow-up turn (see injectWorkflowResult) carrying the outcome.
      // Workflows never wrap a chat turn.
      try {
        await s.agent.run(
          history: s.history,
          userInput: input,
          cancelSignal: cancel.future,
          toolInterruptSignal: toolInterrupt.future,
        );
      } catch (e, st) {
        s.host.showMessage('error: $e\n', style: HostMessageStyle.error);
        if (environment.env['COCOON_DEBUG'] == '1') {
          s.host.showMessage('$st\n', style: HostMessageStyle.dim);
        }
      }
    }

    // A turn that stopped abnormally (budget trip, provider/API error, cut-off
    // stream, action cap, max steps) gets its reason persisted as a synthetic
    // assistant message, so a quit + restore still shows WHY the turn died —
    // the live notice is display-only. A cancelled turn rolls back below and
    // drops this with the rest of the exchange.
    final aborted = s.agent.abortedReason;
    if (aborted != null && !cancel.isCompleted) {
      s.history.add(
        Message(
          role: Role.assistant,
          content: [TextBlock('[turn aborted: $aborted]')],
        ),
      );
    }

    if (cancel.isCompleted) {
      // Cancelled: drop the exchange this turn appended (its user message +
      // any partial assistant/tool messages). Nothing else can have appended
      // during the unwind above: submissions and injected turns see
      // isRunning still set (the markers are only torn down below) and queue
      // instead; the drain is the sole next-turn starter and runs after.
      if (s.history.length > preLen) {
        s.history.removeRange(preLen, s.history.length);
      }
      // Roll the recorder back to the pre-turn state. The user message was
      // persisted up front; cancel discards the entire exchange, so remove it
      // from disk too — replace atomically rewrites the file with [s.history],
      // which is now back to the pre-turn messages.
      // Shutdown preserves the prompt already flushed for resume; explicit
      // operator cancellation still rolls the exchange back on disk.
      if (rec != null && !_closing) {
        try {
          await rec.replace(s.history);
        } catch (e) {
          s.host.showMessage(
            'session write failed: $e\n',
            style: HostMessageStyle.error,
          );
        }
      }
      // #31 queue survival: the backlog is the operator's typed work —
      // cancelling a run must not destroy it (guardrails proposal §3C).
      // The turn's exchange is rolled back above, but the queue is NOT
      // cleared: it drains below, exactly as after a finished turn.
    } else {
      // Persist the turn's new messages, skipping the user message at index
      // preLen — it was persisted before the turn started above.
      if (rec != null) {
        for (final m in s.history.skip(preLen + 1)) {
          try {
            await rec.append(m);
          } catch (e) {
            s.host.showMessage(
              'session write failed: $e\n',
              style: HostMessageStyle.error,
            );
            break;
          }
        }
      }
    }
  }

  Future<void> _maybeAutoCompact(Conversation s, String input) async {
    final estimate = TokenBudget.estimateInputTokens(s.agent.system, [
      ...s.history,
      Message(role: Role.user, content: [TextBlock(input)]),
    ], s.agent.tools.schemas);
    if (estimate <= autoCompactThreshold) return;

    final before = s.history.length;
    final compacted = await s.agent.compact(
      s.history,
      preserveRecent: autoCompactPreserveRecent,
      cancelSignal: s.cancelCompleter?.future,
    );
    if (!compacted) return;

    final rec = s.recorder;
    if (rec != null) {
      try {
        await rec.replace(s.history);
      } catch (e) {
        s.host.showMessage(
          'session write failed: $e\n',
          style: HostMessageStyle.error,
        );
      }
    }
    s.host.showMessage(
      '(auto-compacted $before → ${s.history.length} messages)\n',
      style: HostMessageStyle.dim,
    );
  }

  /// The synthetic user-role prompt handing [run]'s outcome to the launching
  /// agent. Goes through the normal turn path ([_startTurn]/[_runTurn]), so it
  /// is echoed, persisted, and activity-managed like any turn.
  String _workflowOutcomePrompt(WorkflowRun run) {
    final name = run.workflowName;
    final transcript = run.runDir == null || run.runDir!.isEmpty
        ? ''
        : '\nFull transcript: ${run.runDir}\n';
    switch (run.status) {
      case WorkflowRunStatus.completed:
        // The run's real output: the last executed node's full response.
        final output = _truncateWorkflowOutput(run.outcome?.text ?? '');
        return 'Workflow "$name" (run ${run.id}) finished successfully.\n'
            '${output.isEmpty ? '' : '\n$output\n\n'}'
            '$transcript'
            'Report the outcome to the user and act on anything it leaves '
            'open (verify the changes, run tests, propose follow-up).';
      case WorkflowRunStatus.failed:
        final reason = run.outcome?.failureReason.trim() ?? 'unknown';
        return 'Workflow "$name" (run ${run.id}) failed.\n'
            'Reason: $reason\n\n'
            '$transcript'
            'Report the failure to the user and decide whether to fix and '
            'retry.';
      case WorkflowRunStatus.running:
      case WorkflowRunStatus.cancelled:
        // Unreachable: inject only fires on completion; cancelled is skipped.
        return '';
    }
  }

  /// Cap a workflow's output text in the completion prompt — the full response
  /// lives in the run directory; the turn only needs enough to report and act.
  String _truncateWorkflowOutput(String text, {int maxChars = 4000}) {
    final t = text.trim();
    if (t.length <= maxChars) return t;
    return '${t.substring(0, maxChars)}\n\n[…truncated — full output in the '
        'run transcript]';
  }
}
