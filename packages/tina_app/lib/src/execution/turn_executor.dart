import 'dart:async';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina_engine/invocation.dart' as engine show Invocation;
import 'interrupts.dart';
import 'package:tina_app/src/session/conversation.dart';
import 'package:tina_app/src/workflows/workflow_supervisor.dart';
import 'package:tina_app/src/platform/environment.dart';
import 'input_routes.dart';
import '../session/message_queue.dart';

enum TurnState { idle, running, cancelling, closed }

enum TurnSubmission { started, queued, rejected }

class _Admission {
  final cancel = Completer<void>();
  final done = Completer<void>();
  bool discard = false;
}

class _TurnSlot {
  final Conversation conversation;
  final Completer<void> idle = Completer<void>();
  engine.Invocation? invocation;
  TurnState state = TurnState.running;
  _TurnSlot(this.conversation);
}

/// Sole admission/drain owner. A cancellation request does not release a slot.
class TurnExecutor {
  final Conversation? Function(String id) findConversation;
  final Future<void> Function(Conversation conversation)? persistUsage;
  final void Function()? onChanged;

  /// Called when an admitted turn starts (after any queue wait). The returned
  /// callback observes that exact turn's completion, before the queue drains.
  /// Mutable: the TUI coordinator installs the goal judge after the owning
  /// SessionController (and its late executor) exists. Late assignment races
  /// nothing — turns are admitted only after the controller runs.
  void Function(bool completed)? Function(Conversation, String)? onTurnStarted;

  /// A registry owned by this turn, created when queued work actually starts.
  final ToolRegistry? Function(Conversation, String)? toolsForTurn;
  final Environment environment;
  final InputRoutes? inputRoutes;
  final Invocations invocations;
  final Interrupts? interrupts;
  int _nextInput = 0;
  engine.Invocation? activeInvocation(String id) => _slots[id]?.invocation;
  int autoCompactThreshold;
  final int autoCompactPreserveRecent;
  final _slots = <String, _TurnSlot>{};
  final _closed = <String>{};
  final _admissions = <String, List<_Admission>>{};
  final _observed = <Conversation>{};
  bool _closing = false;
  Future<void>? _shutdown;
  TurnExecutor({
    required this.findConversation,
    this.persistUsage,
    this.onChanged,
    this.onTurnStarted,
    this.toolsForTurn,
    this.environment = const PlatformEnvironment(),
    this.inputRoutes,
    this.autoCompactThreshold = 0,
    this.autoCompactPreserveRecent = 2,
  }) : invocations = inputRoutes?.invocations ?? Invocations(),
       interrupts = inputRoutes?.scope.lookup(interruptsServiceKey);

  TurnState state(String id) {
    final conversation = _slots[id]?.conversation ?? findConversation(id);
    if (_closing ||
        _closed.contains(id) ||
        conversation == null ||
        conversation.isClosed) {
      return TurnState.closed;
    }
    return _slots[id]?.state ??
        (_admissions.containsKey(id) ? TurnState.running : TurnState.idle);
  }

  TurnSubmission submit(String id, String prompt, {bool route = true}) {
    final conversation = findConversation(id);
    if (_closing ||
        _closed.contains(id) ||
        conversation == null ||
        conversation.isClosed) {
      return TurnSubmission.rejected;
    }
    final call = invocations.create(
      component: const ComponentInfo('tina.agent', 'Agent'),
      conversationId: id,
      inputId: '${++_nextInput}',
    );
    final routes = inputRoutes;
    if (routes == null ||
        (!routes.hasProcessors && !_admissions.containsKey(id))) {
      return _submitReady(conversation, prompt, route: route, invocation: call);
    }
    // One close listener per conversation, rather than retaining a detached
    // history snapshot through a new close-future listener for every prompt.
    if (_observed.add(conversation)) {
      conversation.closeSignal.then((_) {
        cancelInputs(id);
        _observed.remove(conversation);
      });
    }
    final pending = _admissions.putIfAbsent(id, () => []);
    final previous = pending.lastOrNull?.done.future;
    final result = previous != null || _slots.containsKey(id)
        ? TurnSubmission.queued
        : TurnSubmission.started;
    final admission = _Admission();
    pending.add(admission);
    conversation.pendingInputs++;
    conversation.inputCompletion = admission.done.future;
    // Start independent classification immediately, but commit its decision
    // after earlier submissions. Slow work never owns the editor's readLine.
    final prepared = route
        ? routes.prepare(
            text: prompt,
            conversationId: id,
            history: conversation.history,
            cancelSignal: admission.cancel.future,
            target: call,
          )
        : Future<PreparedInput?>.value(null);
    unawaited(() async {
      var admitted = false;
      try {
        final input = await prepared;
        if (previous != null) await previous;
        if (admission.discard ||
            _closing ||
            conversation.isClosed ||
            _closed.contains(id) ||
            !identical(findConversation(id), conversation))
          return;
        if (call.isCancelled) return;
        if (input?.outcome == InputOutcome.handled) return;
        _submitReady(
          conversation,
          input?.text ?? prompt,
          route: route,
          prepared: input,
          invocation: call,
        );
        admitted = true;
      } finally {
        if (!admitted) call.cancel('Input not admitted');
        pending.remove(admission);
        if (pending.isEmpty) _admissions.remove(id);
        conversation.pendingInputs--;
        if (identical(conversation.inputCompletion, admission.done.future)) {
          conversation.inputCompletion = null;
        }
        admission.done.complete();
        _changed();
      }
    }());
    _changed();
    return result;
  }

  TurnSubmission _submitReady(
    Conversation conversation,
    String prompt, {
    required bool route,
    PreparedInput? prepared,
    required engine.Invocation invocation,
  }) {
    final id = conversation.id;
    if (_slots.containsKey(id)) {
      conversation.messageQueue.enqueue(
        prompt,
        route: route,
        prepared: prepared,
        invocation: invocation,
      );
      return TurnSubmission.queued;
    }
    final slot = _TurnSlot(conversation)..invocation = invocation;
    _slots[id] = slot;
    conversation.turnCompletion = slot.idle.future;
    unawaited(
      _drain(slot, (
        text: prompt,
        route: route,
        prepared: prepared,
        invocation: invocation,
      )),
    );
    return TurnSubmission.started;
  }

  /// Emergency cancellation also covers input not yet admitted to the queue.
  bool cancelInputs(String id) {
    final hadCalls = invocations.active.any(
      (call) => call.conversationId == id,
    );
    interrupts?.cancelAll(conversationId: id);
    invocations.cancelAll(conversationId: id, reason: 'Cancelled by user');
    final background = inputRoutes?.cancelBackground(id) ?? false;
    final pending = _admissions[id];
    if (pending == null) return background || hadCalls;
    for (final item in pending) {
      item.discard = true;
      if (!item.cancel.isCompleted) item.cancel.complete();
    }
    return true;
  }

  bool cancel(String id) {
    final slot = _slots[id];
    if (slot == null) {
      final first = _admissions[id]?.firstOrNull;
      if (first == null) return false;
      if (!first.cancel.isCompleted) first.cancel.complete();
      return true;
    }
    slot.invocation?.cancel('Cancelled by user');
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
    final result = submit(
      run.conversationId,
      _workflowOutcomePrompt(run),
      route: false,
    );
    if (result == TurnSubmission.queued) {
      try {
        findConversation(run.conversationId)?.host.showMessage(
          '[workflow "${run.workflowName}" finished — result queued]\n',
          style: HostMessageStyle.dim,
        );
      } catch (_) {}
    }
  }

  Future<void> whenIdle(String id) async {
    while (_admissions.containsKey(id) || _slots.containsKey(id)) {
      final pending = _admissions[id]?.lastOrNull?.done.future;
      if (pending != null) await pending;
      final turn = _slots[id]?.idle.future;
      if (turn != null) await turn;
    }
  }

  Future<void> close(String id) {
    _closed.add(id);
    final c = findConversation(id);
    c?.beginClose();
    cancelInputs(id);
    cancel(id);
    return whenIdle(id);
  }

  Future<void> shutdown() => _shutdown ??= _stop();
  Future<void> _stop() async {
    _closing = true;
    final ids = {
      ..._slots.keys,
      ..._admissions.keys,
      ..._observed.map((conversation) => conversation.id),
    };
    await Future.wait(ids.map(close));
  }

  void _changed() {
    try {
      onChanged?.call();
    } catch (_) {}
  }

  Future<void> _drain(_TurnSlot slot, QueuedInput first) async {
    final s = slot.conversation;
    QueuedInput? next = first;
    try {
      while (next != null &&
          !_closing &&
          !s.isClosed &&
          !_closed.contains(s.id) &&
          identical(findConversation(s.id), s)) {
        await interrupts?.ready(s.id);
        if (_closing || s.isClosed) break;
        final call =
            next.invocation ??
            invocations.create(
              component: const ComponentInfo('tina.agent', 'Agent'),
              conversationId: s.id,
            );
        if (call.isCancelled) {
          next = s.messageQueue.take();
          continue;
        }
        slot.invocation = call;
        slot.state = TurnState.running;
        s.cancelCompleter = Completer<void>();
        s.toolInterruptCompleter = Completer<void>();
        final cancel = s.cancelCompleter!;
        final activity = RunActivity(s.host);
        var cancellationShown = false;
        final detach = call.listen(() {
          if (call.isCancelled) {
            if (!cancel.isCompleted) cancel.complete();
            activity.complete();
            if (!cancellationShown) {
              cancellationShown = true;
              final reason = call.cancelReason;
              s.host.notice(
                reason is InterruptReason ? '\n[$reason]\n' : '\n[cancelled]\n',
                kind: NoticeKind.warning,
              );
            }
          }
        });
        cancel.future.then((_) {
          if (!call.isDone) call.cancel('Cancelled by user');
        });
        _changed();
        void Function(bool)? finish;
        var completed = false;
        try {
          final turnTools = toolsForTurn?.call(s, next.text);
          finish = onTurnStarted?.call(s, next.text);
          final input = next;
          completed = await call.run(
            (_) => _runTurn(
              s,
              input.text,
              route: input.route,
              prepared: input.prepared,
              turnTools: turnTools,
            ),
          );
        } catch (_) {
          // Cosmetic host failures must not strand admission or shutdown.
        } finally {
          try {
            finish?.call(completed);
          } catch (e) {
            s.host.showMessage(
              'Could not record turn result: $e\n',
              style: HostMessageStyle.warning,
            );
          }
          detach();
          activity.complete();
          try {
            await persistUsage?.call(s);
          } catch (_) {}
        }
        await interrupts?.ready(s.id);
        next = s.messageQueue.take();
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

  Future<bool> _runTurn(
    Conversation s,
    String input, {
    bool route = true,
    PreparedInput? prepared,
    ToolRegistry? turnTools,
  }) async {
    final host = InvocationHost(s.host, InvocationContext.current!.invocation);
    final cancel = s.cancelCompleter!;
    final toolInterrupt = s.toolInterruptCompleter!;
    host.showSeparator();
    host.showMessage(
      '${prepared?.originalText ?? input}\n',
      style: HostMessageStyle.user,
    );
    host.showSeparator();

    if (route && inputRoutes != null) {
      final ready =
          prepared ??
          await inputRoutes!.prepare(
            text: input,
            conversationId: s.id,
            history: s.history,
            cancelSignal: cancel.future,
          );
      if (ready.context.target == null)
        cancel.future.then((_) => ready.cancel());
      final outcome = await inputRoutes!.deliver(
        ready,
        history: s.history,
        cancelSignal: cancel.future,
        host: host,
        recorder: s.recorder,
      );
      input = ready.text;
      if (outcome != InputOutcome.pass) {
        return outcome == InputOutcome.handled && !cancel.isCompleted;
      }
    }

    // Auto-compact before the turn if the about-to-be-sent request is large.
    // The summary is persisted via replace before new turn progress starts.
    // Compact failure must not strand the markers armed above: the failure
    // completes the cancel completer, so the turn unwinds through the cancel
    // path (preserving progress and the queue) instead of hanging busy.
    if (autoCompactThreshold > 0) {
      try {
        await _maybeAutoCompact(s, input, turnTools: turnTools);
      } catch (e, st) {
        host.showMessage('error: $e\n', style: HostMessageStyle.error);
        if (environment.env['COCOON_DEBUG'] == '1') {
          host.showMessage('$st\n', style: HostMessageStyle.dim);
        }
        if (!cancel.isCompleted) cancel.complete();
      }
    }

    // Retain progress on every exit: cancellation cannot undo tool effects.
    final preLen = s.history.length;
    final rec = s.recorder;
    var failed = false;
    var ran = false;

    // Save the prompt even for a replacement driver that does not publish
    // incremental progress. The default driver's first append is deduplicated.
    if (!cancel.isCompleted) {
      final userMessage = Message(role: Role.user, content: [TextBlock(input)]);
      var userAlreadySaved = false;
      if (rec != null) {
        try {
          await rec.append(userMessage);
          userAlreadySaved = true;
        } catch (e) {
          host.showMessage(
            'session write failed: $e\n',
            style: HostMessageStyle.error,
          );
        }
      }

      Future<void> saveAppend(Message message) async {
        if (userAlreadySaved &&
            message.role == Role.user &&
            message.content.length == 1 &&
            message.content.single is TextBlock &&
            (message.content.single as TextBlock).text == input) {
          userAlreadySaved = false;
          return;
        }
        userAlreadySaved = false;
        try {
          await rec?.append(message);
        } catch (e) {
          host.showMessage(
            'session write failed: $e\n',
            style: HostMessageStyle.error,
          );
        }
      }

      Future<void> saveReplace(List<Message> messages) async {
        userAlreadySaved = false;
        try {
          await rec?.replace(messages);
        } catch (e) {
          host.showMessage(
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
        if (!cancel.isCompleted) {
          ran = true;
          await s.driver.run(
            history: s.history,
            userInput: input,
            cancelSignal: cancel.future,
            toolInterruptSignal: toolInterrupt.future,
            turnTools: turnTools,
            onHistoryAppend: rec == null ? null : saveAppend,
            onHistoryReplace: rec == null ? null : saveReplace,
          );
        } else {
          // Cancellation during the initial write keeps memory and disk aligned.
          s.history.add(userMessage);
        }
      } catch (e, st) {
        failed = true;
        host.showMessage('error: $e\n', style: HostMessageStyle.error);
        if (environment.env['COCOON_DEBUG'] == '1') {
          host.showMessage('$st\n', style: HostMessageStyle.dim);
        }
      }
    }

    // A turn that stopped abnormally (budget trip, provider/API error, cut-off
    // stream, action cap, max steps) gets its reason persisted as a synthetic
    // assistant message, so a quit + restore still shows WHY the turn died —
    // the live notice is display-only. Cancelled turns retain their progress too.
    final aborted = s.driver.abortedReason;
    if (aborted != null && !cancel.isCompleted) {
      s.history.add(
        Message(
          role: Role.assistant,
          content: [TextBlock('[turn aborted: $aborted]')],
        ),
      );
    }

    if (cancel.isCompleted && (ran || s.history.length > preLen)) {
      final reason = InvocationContext.current?.invocation.cancelReason;
      s.history.add(
        Message(
          role: Role.assistant,
          content: [
            TextBlock(reason is InterruptReason ? '[$reason]' : '[cancelled]'),
          ],
        ),
      );
    }
    // Final reconciliation covers synthetic status messages and replacement
    // drivers that do not emit observers. Per-call writes above already protect
    // completed tools against a crash or a later approval that never settles.
    if (rec != null && (ran || s.history.length > preLen)) {
      try {
        await rec.replace(s.history);
      } catch (e) {
        host.showMessage(
          'session write failed: $e\n',
          style: HostMessageStyle.error,
        );
      }
    }
    return !cancel.isCompleted &&
        !toolInterrupt.isCompleted &&
        !failed &&
        aborted == null &&
        s.history.length > preLen &&
        s.history.last.role == Role.assistant &&
        s.history.last.content.any(
          (b) => b is TextBlock && b.text.trim().isNotEmpty,
        );
  }

  Future<void> _maybeAutoCompact(
    Conversation s,
    String input, {
    ToolRegistry? turnTools,
  }) async {
    final estimate = TokenBudget.estimateInputTokens(s.driver.system, [
      ...s.history,
      Message(role: Role.user, content: [TextBlock(input)]),
    ], (turnTools ?? s.driver.tools).schemas);
    if (estimate <= autoCompactThreshold) return;

    final before = s.history.length;
    final compacted = await s.driver.compact(
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
        InvocationHost(
          s.host,
          InvocationContext.current!.invocation,
        ).showMessage(
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
