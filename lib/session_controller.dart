import 'dart:async';
import 'dart:io';

import 'package:tina_engine/tina_engine.dart';

import 'conversation.dart';
import 'environment/environment_index.dart';
import 'pipeline/workflow_supervisor.dart';
import 'platform/environment.dart';
import 'session_commands/command_context.dart';
import 'session_commands/session_command_handlers.dart';
import 'session_manager.dart';
import 'summaries/summary_index.dart';

/// Reads a single line of user input given the [prompt]. Returns null when the
/// host's input closed (EOF). Abstracts the terminal's line editor so the
/// controller knows nothing about it; a terminal wires this to
/// `LineEditor.readLine`, a headless host could back it with stdin.
typedef ReadLine = Future<String?> Function(String prompt);

/// UI-agnostic session and turn orchestrator, extracted from the old `Repl`.
///
/// The controller owns the input loop, agent-turn dispatch (fire-and-forget,
/// one queued backlog per conversation), cancel, auto-compact, and persistence.
/// Slash-command dispatch is delegated to [SessionCommandHandlers] through the
/// [CommandContext] seam this class implements, so the handlers can be read and
/// tested in isolation. The controller reaches the frontend *only* through each
/// conversation's [HostInterface] — `showMessage`/`showSeparator`/`clear` for
/// output, `setActivity`/`setIdle` for the activity signal — and never touches a
/// terminal type (`Screen`, `LineEditor`, `ChatRegion`, `Spinner`).
///
/// The terminal composition root ([TuiCoordinator]) supplies a [readLine] backed
/// by the shared line editor, wires ESC to [cancelActiveTurn], and forwards
/// focus switches (an editor re-render) via [onActiveFocusChanged]. A headless
/// runner can supply a stdin-backed [readLine] and leave the cosmetic callbacks
/// null.
class SessionController implements CommandContext {
  final SessionManager sessionManager;
  final ReadLine readLine;
  final SessionStore? sessionStore;
  final Future<void>? exitSignal;

  /// Called whenever the set of sessions or the active session changes, so the
  /// host can refresh a session menu. Fired on session switches *and* on turn
  /// start/end (so a running indicator can update).
  final void Function()? onSessionsChanged;

  /// Called when the active conversation changes because the user switched
  /// sessions or conversations (`/session new|switch`, the View menu). The
  /// terminal uses it to re-render the line editor's input after the chat area
  /// was repainted underneath an active [readLine]. Not fired on turn
  /// boundaries, which don't move focus.
  final void Function()? onActiveFocusChanged;

  /// Capture the line editor's current draft (buffer + cursor) for the session
  /// being switched away from. Returns null when nothing is being edited. Wired
  /// by the TUI coordinator; null in headless.
  ({String buffer, int cursor})? Function()? saveInput;

  /// Restore a saved draft (or clear it) into the line editor for the session
  /// being switched to. Wired by the TUI coordinator; null in headless.
  void Function(String buffer, int cursor)? restoreInput;

  /// Per-session draft input saved across switches, keyed by session id. Lets a
  /// half-typed prompt survive switching to another session and back — tmux-
  /// style independent input per session.
  final Map<String, ({String buffer, int cursor})> _sessionInput = {};

  /// Hooks for built-in commands, keyed by command word (e.g. `/clear`). When
  /// a recognized command is entered, its hook — if any — is awaited *before*
  /// the default behavior runs (after the echoed prompt and separator), so the
  /// hook can prepare or clear state the default handler then acts on. A hook
  /// may be async. Kept generic so features can react to commands without the
  /// controller growing a field per feature.
  final Map<String, FutureOr<void> Function()> commandHooks = {};

  /// Open the settings overlay (`/settings`), pre-filled with the current
  /// config. Wired by the TUI coordinator; null in headless. Mutable so the
  /// coordinator can set it after constructing the controller.
  Future<void> Function()? openSettings;

  /// Open the system-prompt editor overlay (`/prompts`), pre-filled with the
  /// current overrides. Wired by the TUI coordinator; null in headless.
  Future<void> Function()? openPrompts;

  /// Open the spawn overlay (`/spawn`) to pick a model and start a sub-agent.
  /// Wired by the TUI coordinator; null in headless.
  @override
  Future<void> Function()? openSpawn;

  /// Open the branch overlay (`/branch`) to fork the active conversation into a
  /// new side panel, copying its history. Wired by the TUI coordinator; null in
  /// headless.
  @override
  Future<void> Function()? openBranch;

  /// Open the model-picker overlay (`/model`) to switch the active
  /// conversation's provider/model. Wired by the TUI coordinator; null in headless.
  @override
  Future<void> Function()? openModelPicker;

  /// Open the session-picker overlay (Alt+S or `/session switch` with no arg).
  /// Wired by the TUI coordinator; null in headless.
  @override
  Future<void> Function()? openSessionPicker;

  /// Display the image at [path] in the focused panel (`/image`). Wired by the
  /// TUI coordinator; null in headless.
  @override
  Future<void> Function(String path)? openImage;

  /// The per-directory summary sidecar service (`/index`). Wired by the TUI
  /// coordinator and the headless runner from the live [AppComposition]; null
  /// when no composition is available (then `/index` falls back to an ad-hoc
  /// in-chat review).
  @override
  SummaryIndex? summaryIndex;

  /// The environment agent service (the `/index` dance's environment branch
  /// and first load). Wired by the TUI coordinator from the live
  /// [AppComposition]; null in headless, which never auto-runs setup.
  @override
  EnvironmentIndex? environmentIndex;

  /// Ask a yes/no confirmation (`/index` up-to-date re-run prompt). Wired by
  /// the TUI via the shared line editor; null in headless.
  @override
  Future<bool> Function(String prompt)? confirm;

  /// Auto-compact: when an incoming turn's estimated input tokens exceed this,
  /// summarize the older history first (keeping [autoCompactPreserveRecent]
  /// recent human turns). 0 disables. Mutable at runtime via /auto-compact.
  int autoCompactThreshold;

  /// How many recent human turns auto-compact leaves uncompressed.
  final int autoCompactPreserveRecent;

  /// The host environment (env vars + OS), so the controller doesn't read
  /// [Platform] directly. Defaults to the real platform.
  final Environment environment;

  /// The slash-command handlers, operating on this controller through the
  /// [CommandContext] seam. Lazy so it can capture `this`.
  late final SessionCommandHandlers _commands = SessionCommandHandlers(this);

  /// Two-press Esc arming. Set to true on first Esc while a turn is running;
  /// the second Esc actually cancels. Cleared when the turn ends naturally.
  bool _cancelArmed = false;

  /// The directory holding workflow `.dot` files. Wired by the TUI/headless
  /// runner; null when unavailable.
  @override
  Directory? workflowsDir;

  /// The `[default] workflow` config value: names the default workflow file
  /// shown by `/workflow list` (the seeded `default.dot` unless configured
  /// otherwise; `"none"` is explicit). Launched by the main agent's
  /// `launch_workflow` tool by default. Wired by the TUI coordinator; null when
  /// unset.
  String? defaultWorkflow;

  /// Open the visual graph viewer. Wired by the TUI.
  @override
  Future<void> Function(String name)? openWorkflowViewer;

  /// Open the visual node editor. Wired by the TUI.
  @override
  Future<void> Function({String? name, bool isNew})? openWorkflowEditor;

  /// Open the full-output viewer for a capped tool call (`/output`). Wired by
  /// the TUI; null in headless.
  @override
  Future<void> Function(int index)? openToolOutput;

  /// The process-wide token ledger (`/spend`). Wired by the composition root;
  /// used to persist usage into the active session's manifest.
  @override
  SpendLedger? spendLedger;

  /// Cancels an in-flight background `/index` fleet run, when one is running.
  Completer<void>? _indexCancel;

  /// Whether a background `/index` fleet run is in flight (guards a second
  /// concurrent run).
  bool get isIndexRunning => _indexCancel != null;

  /// Cancels an in-flight background environment-agent run, when one is
  /// running.
  Completer<void>? _environmentCancel;

  /// Whether a background environment-agent run is in flight.
  bool get isEnvironmentRunning => _environmentCancel != null;

  /// Launch the environment agent in the background on [conv] (first load, or
  /// the `/index` dance's environment branch): returns immediately, the
  /// agent's output streams into [conv]'s host, and Esc-Esc cancels. Warns and
  /// no-ops when a run is already in flight.
  @override
  Future<void> Function(Conversation conv)? get runBackgroundEnvironment =>
      _runBackgroundEnvironment;

  Future<void> _runBackgroundEnvironment(Conversation conv) {
    if (isEnvironmentRunning) {
      conv.host.showMessage(
          'the environment agent is already running in the background\n',
          style: HostMessageStyle.warning);
      return Future.value();
    }
    final cancel = Completer<void>();
    _environmentCancel = cancel;
    unawaited(_doBackgroundEnvironment(conv, cancel: cancel));
    return Future.value();
  }

  /// The background environment-agent task. Posts start/completion notices to
  /// [conv]'s host and clears the guard when done.
  Future<void> _doBackgroundEnvironment(
    Conversation conv, {
    required Completer<void> cancel,
  }) async {
    final idx = environmentIndex;
    if (idx == null) {
      _environmentCancel = null;
      return;
    }
    try {
      final ok = await idx.refresh(
        host: conv.host,
        cancelSignal: cancel.future,
      );
      if (cancel.isCompleted) {
        conv.host.showMessage('[environment agent cancelled]\n',
            style: HostMessageStyle.warning);
      } else if (ok) {
        conv.host.showMessage(
            'Environment record updated (ENVIRONMENT.md).\n',
            style: HostMessageStyle.success);
      } else {
        conv.host.showMessage(
            'environment agent did not complete — the record stays stale\n',
            style: HostMessageStyle.warning);
      }
    } catch (e) {
      conv.host.showMessage('environment agent failed: $e\n',
          style: HostMessageStyle.error);
    } finally {
      _environmentCancel = null;
      unawaited(_flushUsage());
    }
  }

  /// Launch the summary fleet in the background on [conv] (`/index` in the
  /// TUI): returns immediately, the fleet's output streams into [conv]'s host,
  /// and Esc-Esc cancels. Warns and no-ops when a run is already in flight.
  @override
  Future<void> Function(Conversation conv, List<String>? dirs,
      {bool repartition})? get runBackgroundIndex => _runBackgroundIndex;

  Future<void> _runBackgroundIndex(Conversation conv, List<String>? dirs,
      {bool repartition = false}) {
    if (isIndexRunning) {
      conv.host.showMessage(
          '/index is already running in the background\n',
          style: HostMessageStyle.warning);
      return Future.value();
    }
    final cancel = Completer<void>();
    _indexCancel = cancel;
    unawaited(_doBackgroundIndex(conv, dirs,
        repartition: repartition, cancel: cancel));
    return Future.value();
  }

  /// The background fleet task. Posts start/completion notices to [conv]'s
  /// host, clears [_indexCancel] when done (when it's still ours — a newer
  /// run can't start while this one holds the guard, so it always is).
  Future<void> _doBackgroundIndex(
    Conversation conv,
    List<String>? dirs, {
    required bool repartition,
    required Completer<void> cancel,
  }) async {
    final idx = summaryIndex;
    if (idx == null) {
      _indexCancel = null;
      return;
    }
    final n = dirs?.length;
    conv.host.showMessage(
        'Indexing ${n == null ? 'all dirs' : '$n ${n == 1 ? 'dir' : 'dirs'}'} '
        'in the background (Esc-Esc to cancel)…\n');
    try {
      final r = await idx.refresh(
        repartition: repartition,
        dirs: dirs,
        host: conv.host,
        cancelSignal: cancel.future,
      );
      if (cancel.isCompleted) {
        conv.host.showMessage('[index cancelled]\n',
            style: HostMessageStyle.warning);
      } else {
        final sha = r.status.headSha;
        final at = sha == null
            ? ''
            : ' @ ${sha.length >= 7 ? sha.substring(0, 7) : sha}';
        conv.host.showMessage(
            'Indexed ${r.regenerated} '
            '${r.regenerated == 1 ? 'directory' : 'directories'}$at.\n',
            style: HostMessageStyle.success);
      }
    } catch (e) {
      conv.host.showMessage('index failed: $e\n',
          style: HostMessageStyle.error);
    } finally {
      _indexCancel = null;
      _cancelArmed = false;
      unawaited(_flushUsage());
    }
  }

  SessionController({
    required this.sessionManager,
    required this.readLine,
    this.sessionStore,
    this.exitSignal,
    this.onSessionsChanged,
    this.onActiveFocusChanged,
    this.autoCompactThreshold = 0,
    this.autoCompactPreserveRecent = 2,
    this.environment = const PlatformEnvironment(),
  });

  @override
  Conversation get active => sessionManager.activeConversation;

  /// The interactive input → turn loop. Always sits in [readLine]; agent turns
  /// run fire-and-forget per conversation, so the user can keep typing, switch
  /// sessions, or queue messages while a turn is in flight. Returns when [exitSignal]
  /// fires or input reaches EOF. ESC cancels the active conversation's turn
  /// (wired to [cancelActiveTurn] by the host).
  Future<void> run() async {
    active.host.setIdle(true);

    while (true) {
      final input = exitSignal != null
          ? await Future.any<String?>([
              readLine('> '),
              exitSignal!.then((_) => null),
            ])
          : await readLine('> ');
      if (input == null) {
        active.host.newline();
        unawaited(_flushUsage()); // persist spend on quit
        return;
      }

      final trimmed = input.trim();
      if (trimmed.isEmpty) continue;

      final cmd = await _commands.dispatch(trimmed);
      if (cmd is CmdExit) {
        unawaited(_flushUsage()); // persist spend on quit
        return;
      }
      if (cmd is CmdHandled) continue;
      if (cmd case CmdRun(:final prompt)) {
        // A command that injects a fixed prompt (e.g. /index): run it as a
        // normal turn with the prompt as the user input, not the raw command
        // word. Reuses the same turn path a typed line takes.
        final rs = active;
        if (rs.isRunning) {
          rs.messageQueue.enqueue(prompt);
          active.host.showMessage(
              '$trimmed  [queued — ${rs.messageQueue.length} pending]\n',
              style: HostMessageStyle.dim);
        } else {
          _startTurn(rs, prompt);
        }
        continue;
      }

      // Plain text (or an unknown /command) goes to the active session.
      final s = active;
      if (s.isRunning) {
        s.messageQueue.enqueue(trimmed);
        active.host.showMessage(
            '$trimmed  [queued — ${s.messageQueue.length} pending]\n',
            style: HostMessageStyle.dim);
      } else {
        _startTurn(s, trimmed);
      }
    }
  }

  /// ESC handler: cancel the active conversation's in-flight turn, or a
  /// background `/index` fleet run when no turn is running. Returns true
  /// (handled) when something was running and was signalled, so the line editor
  /// consumes the Esc instead of falling through to its own Esc handling; false
  /// when nothing was running (the editor then activates the menu bar).
  bool cancelActiveTurn() {
    final s = active;
    if (!s.isRunning) {
      // No turn, but a background index run may be cancellable.
      if (isIndexRunning || isEnvironmentRunning) {
        if (!_cancelArmed) {
          _cancelArmed = true;
          s.host.showMessage(
            'Press Esc again to cancel the background run\n',
            style: HostMessageStyle.warning,
          );
          return true;
        }
        _cancelArmed = false;
        _indexCancel?.complete();
        _environmentCancel?.complete();
        return true;
      }
      _cancelArmed = false;
      return false;
    }
    if (!_cancelArmed) {
      // First Esc: warn and arm.
      _cancelArmed = true;
      s.host.showMessage(
        'Press Esc again to cancel\n',
        style: HostMessageStyle.warning,
      );
      return true; // consume the Esc so it doesn't fall through to input clear
    }
    // Second Esc: cancel.
    _cancelArmed = false;
    s.cancelCompleter?.complete();
    return true;
  }

  // -- Agent turns --------------------------------------------------------

  void _startTurn(Conversation s, String input) =>
      unawaited(_runTurn(s, input));

  /// Run one turn for [s] without blocking the loop. On completion, persists
  /// history (or rolls back on cancel) and drains one queued message. Output is
  /// written to [s]'s own host, so a turn that gets switched to the background
  /// mid-flight still renders into its (detached) region.
  Future<void> _runTurn(Conversation s, String input) async {
    s.host.showMessage('$input\n', style: HostMessageStyle.user);
    s.host.showSeparator();

    // Auto-compact before the turn if the about-to-be-sent request is large.
    // Runs before preLen is captured so the new turn's messages are all that's
    // appended on completion (the summary itself is persisted via replace).
    if (autoCompactThreshold > 0) {
      await _maybeAutoCompact(s, input);
    }

    final preLen = s.history.length;
    final cancel = Completer<void>();
    s.cancelCompleter = cancel;
    final isActive = identical(s, active);
    if (isActive) s.host.setActivity(true);
    onSessionsChanged?.call();

    // Persist the user's message BEFORE the turn starts, so it survives a quit
    // before the response completes and is restored by `-c`. `agent.run` adds
    // the same message to in-memory history; the post-turn append below skips
    // it, and a cancel rolls it back via replace — so cancel still discards the
    // whole exchange, but a process killed mid-stream no longer loses the prompt.
    final rec = s.recorder;
    final userMessage = Message(role: Role.user, content: [TextBlock(input)]);
    if (rec != null) {
      try {
        await rec.append(userMessage);
      } catch (e) {
        s.host.showMessage(
            'session write failed: $e\n', style: HostMessageStyle.error);
      }
    }

    // Normal turns run the plain agent. A workflow is launched on demand by the
    // agent itself via its `launch_workflow` tool (the supervisor seam wired by
    // the coordinator) — a fire-and-forget call: the run churns in the
    // background while the chat stays open, and its completion injects a
    // follow-up turn (see injectWorkflowResult) carrying the outcome.
    // Workflows never wrap a chat turn.
    try {
      await s.agent.run(
        history: s.history,
        userInput: input,
        cancelSignal: cancel.future,
      );
    } catch (e, st) {
      s.host.showMessage('error: $e\n', style: HostMessageStyle.error);
      if (environment.env['COCOON_DEBUG'] == '1') {
        s.host.showMessage('$st\n', style: HostMessageStyle.dim);
      }
    }

    // A turn that stopped abnormally (budget trip, provider/API error, cut-off
    // stream, action cap, max steps) gets its reason persisted as a synthetic
    // assistant message, so a quit + restore still shows WHY the turn died —
    // the live notice is display-only. A cancelled turn rolls back below and
    // drops this with the rest of the exchange.
    final aborted = s.agent.abortedReason;
    if (aborted != null && !cancel.isCompleted) {
      s.history.add(Message(
        role: Role.assistant,
        content: [TextBlock('[turn aborted: $aborted]')],
      ));
    }

    if (cancel.isCompleted) {
      // Cancelled: drop any partial assistant/tool messages and the backlog.
      if (s.history.length > preLen) {
        s.history.removeRange(preLen, s.history.length);
      }
      // Roll the recorder back to the pre-turn state. The user message was
      // persisted up front; cancel discards the entire exchange, so remove it
      // from disk too — replace atomically rewrites the file with [s.history],
      // which is now back to the pre-turn messages.
      if (rec != null) {
        try {
          await rec.replace(s.history);
        } catch (e) {
          s.host.showMessage(
              'session write failed: $e\n', style: HostMessageStyle.error);
        }
      }
      if (s.messageQueue.isNotEmpty) {
        s.host.showMessage(
            '[${s.messageQueue.length} queued message'
            '${s.messageQueue.length == 1 ? '' : 's'} discarded]\n',
            style: HostMessageStyle.dim);
        s.messageQueue.clear();
      }
    } else {
      // Persist the turn's new messages, skipping the user message at index
      // preLen — it was persisted before the turn started above.
      if (rec != null) {
        for (final m in s.history.skip(preLen + 1)) {
          try {
            await rec.append(m);
          } catch (e) {
            s.host.showMessage('session write failed: $e\n',
                style: HostMessageStyle.error);
            break;
          }
        }
      }
    }

    s.cancelCompleter = null;
    _cancelArmed = false;
    if (identical(s, active)) s.host.setActivity(false);
    onSessionsChanged?.call();

    // Persist the session's token spend so a resumed session restores it.
    unawaited(_flushUsage());

    // Continue the session's backlog, if any.
    final next = s.messageQueue.dequeue();
    if (next != null) _startTurn(s, next);
  }

  /// Persist the ledger's current total into the active session's manifest
  /// (`/spend` restore on resume). Best-effort: a failed write must never
  /// break the turn.
  Future<void> _flushUsage() async {
    final ledger = spendLedger;
    final store = sessionStore;
    if (ledger == null || store == null) return;
    final sid = sessionManager.activeId;
    if (sid.isEmpty) return;
    try {
      await store.updateSessionUsage(sid, ledger.totalTokens);
    } catch (_) {
      // Best-effort; the in-memory ledger is unaffected.
    }
  }

  // -- Workflow completion turns ------------------------------------------

  /// Wake the conversation that launched [run] with a synthetic turn carrying
  /// the run's outcome, so the main agent reports on it and acts (auto agent
  /// turn on completion). Called by the supervisor's `onComplete` hook. No-op
  /// when the run was cancelled (that was already communicated via the stop
  /// path) or its conversation is gone; when the conversation is mid-turn the
  /// prompt is queued and drained when the turn ends, like any typed message.
  void injectWorkflowResult(WorkflowRun run) {
    if (run.status == WorkflowRunStatus.cancelled) return;
    final conv = _findConversation(run.conversationId);
    if (conv == null) return;
    final prompt = _workflowOutcomePrompt(run);
    if (conv.isRunning) {
      conv.messageQueue.enqueue(prompt);
      conv.host.showMessage(
          '[workflow "${run.workflowName}" finished — result queued]\n',
          style: HostMessageStyle.dim);
    } else {
      _startTurn(conv, prompt);
    }
  }

  /// The conversation with id [conversationId] across every session, or null
  /// when it no longer exists (closed/deleted).
  Conversation? _findConversation(String conversationId) {
    for (final session in sessionManager.all) {
      final conv = session.conversationById(conversationId);
      if (conv != null) return conv;
    }
    return null;
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

  /// If the request we're about to send would exceed [autoCompactThreshold]
  /// tokens, summarize the older history (keeping recent turns) before the
  /// agent runs. No-op when under threshold or when there's too little history
  /// to split — `compact` reports that and we leave everything untouched.
  Future<void> _maybeAutoCompact(Conversation s, String input) async {
    final estimate = TokenBudget.estimateInputTokens(
      s.agent.system,
      [
        ...s.history,
        Message(role: Role.user, content: [TextBlock(input)]),
      ],
      s.agent.tools.schemas,
    );
    if (estimate <= autoCompactThreshold) return;

    final before = s.history.length;
    final compacted = await s.agent.compact(s.history,
        preserveRecent: autoCompactPreserveRecent);
    if (!compacted) return;

    final rec = s.recorder;
    if (rec != null) {
      try {
        await rec.replace(s.history);
      } catch (e) {
        s.host.showMessage('session write failed: $e\n',
            style: HostMessageStyle.error);
      }
    }
    s.host.showMessage(
        '(auto-compacted $before → ${s.history.length} messages)\n',
        style: HostMessageStyle.dim);
  }

  // -- Session management (also driven by the View menu) ------------------

  /// Create a new session and switch to it.
  @override
  Future<void> newSession({String? providerId, String? model}) async {
    final fromId = sessionManager.activeId;
    final s = await sessionManager.createSession(
      providerId: providerId,
      model: model,
    );
    sessionManager.switchSession(s.id);
    _swapInput(fromId, s.id);
    active.host.showMessage(
        '(new session ${_shortId(s.id)} — '
        '${s.activeConversation.provider.model})\n',
        style: HostMessageStyle.dim);
    onSessionsChanged?.call();
    onActiveFocusChanged?.call();
  }

  /// Switch to an existing session by id.
  @override
  void switchSession(String id) {
    if (id == sessionManager.activeId) return;
    final fromId = sessionManager.activeId;
    // Persist the outgoing session's spend, then restore the incoming
    // session's recorded spend into the ledger.
    unawaited(_flushUsage());
    sessionManager.switchSession(id);
    _seedUsageFrom(id);
    _swapInput(fromId, id);
    active.host.showMessage(
        '(switched to ${_shortId(id)} — ${active.provider.model})\n',
        style: HostMessageStyle.dim);
    onSessionsChanged?.call();
    onActiveFocusChanged?.call();
  }

  /// Seed the ledger with [sessionId]'s persisted usage (a no-op when the
  /// session has no record yet).
  void _seedUsageFrom(String sessionId) {
    final ledger = spendLedger;
    final store = sessionStore;
    if (ledger == null || store == null) return;
    unawaited(() async {
      try {
        final manifest = await store.loadSession(sessionId);
        ledger.seed(manifest.usageTokens);
      } catch (_) {
        // Unknown session or a read failure: leave the ledger as-is.
      }
    }());
  }

  /// Save the outgoing session's draft input and restore the incoming
  /// session's saved draft (or clear it). No-ops when the TUI hasn't wired
  /// [saveInput]/[restoreInput] (headless).
  void _swapInput(String fromId, String toId) {
    final save = saveInput;
    if (save != null) {
      final saved = save();
      if (saved != null) _sessionInput[fromId] = saved;
    }
    final incoming = _sessionInput.remove(toId);
    restoreInput?.call(incoming?.buffer ?? '', incoming?.cursor ?? 0);
  }

  /// Load a saved session [id] from disk into the active conversation,
  /// replacing its history and replaying it onto the host. Returns true on
  /// success, false (with a host message) when persistence is disabled, the id
  /// is unknown, or the load fails. Shared by `/resume` and the session picker.
  Future<bool> resumeIntoActive(String id) async {
    final s = active;
    final rec = s.recorder;
    if (sessionStore == null || rec == null) {
      s.host.showMessage('(persistence disabled — cannot resume)\n',
          style: HostMessageStyle.dim);
      return false;
    }
    final String activeCid;
    final List<Message> loaded;
    try {
      final manifest = await sessionStore!.loadSession(id);
      activeCid = manifest.activeConversationId;
      loaded = await sessionStore!.loadConversation(id, activeCid);
    } catch (e) {
      s.host.showMessage('cannot resume: $e\n', style: HostMessageStyle.error);
      return false;
    }
    s.history
      ..clear()
      ..addAll(loaded);
    rec.switchTo(id, activeCid);
    s.host.clear();
    replayHistory(s.host, loaded);
    s.host.showMessage('resumed: $id (${loaded.length} messages)\n',
        style: HostMessageStyle.dim);
    return true;
  }

  static String _shortId(String id) =>
      id.length > 6 ? id.substring(id.length - 6) : id;
}
