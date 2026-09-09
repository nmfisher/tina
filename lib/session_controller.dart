import 'session_commands/controller_command_adapter.dart';
import 'package:tina_app/tina_app.dart';
import 'frontend/session_input_state.dart';
import 'dart:async';
import 'dart:io';

import 'package:tina_engine/tina_engine.dart';

import 'session_commands/session_command_handlers.dart';

/// Reads a single line of user input given the [prompt]. Returns null when the
/// host's input closed (EOF). Abstracts the terminal's line editor so the
/// controller knows nothing about it; a terminal wires this to
/// `LineEditor.readLine`, a headless host could back it with stdin.
typedef ReadLine = Future<String?> Function(String prompt);

/// Compatibility frontend facade: owns the read/dispatch loop and optional UI
/// actions. Turn execution and background work are delegated to application
/// services; command families see narrow capabilities through an adapter.
class SessionController {
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
  final SessionInputState inputState = SessionInputState();

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
  Future<void> Function()? openSpawn;

  /// Open the branch overlay (`/branch`) to fork the active conversation into a
  /// new side panel, copying its history. Wired by the TUI coordinator; null in
  /// headless.
  Future<void> Function()? openBranch;

  /// Open the model-picker overlay (`/model`) to switch the active
  /// conversation's provider/model. Wired by the TUI coordinator; null in headless.
  Future<void> Function()? openModelPicker;

  /// Open the session-picker overlay (Alt+S or `/session switch` with no arg).
  /// Wired by the TUI coordinator; null in headless.
  Future<void> Function()? openSessionPicker;

  /// Switch the permission mode (`/permissions <mode>`). Wired by the TUI to
  /// update the shared base policy plus every live conversation's policy;
  /// null in headless (no runtime switch — use the CLI flag).
  void Function(PermissionMode mode)? setPermissionMode;

  /// Display the image at [path] in the focused panel (`/image`). Wired by the
  /// TUI coordinator; null in headless.
  Future<void> Function(String path)? openImage;

  /// The per-directory summary sidecar service (`/index`). Wired by the TUI
  /// coordinator and the headless runner from the live [AppComposition]; null
  /// when no composition is available (then `/index` falls back to an ad-hoc
  /// in-chat review).
  SummaryIndex? summaryIndex;

  /// Environment task instructions and record verification. Execution uses
  /// the main conversation and its normal turn lifecycle. Null in headless.
  EnvironmentIndex? environmentIndex;
  void Function(String conversationId)? onConversationFocusRequested;

  /// Ask a yes/no confirmation (`/index` up-to-date re-run prompt, `/model`'s
  /// "make this the global default"). [body] is optional explanatory text
  /// rendered inside the box under the title. Wired by the TUI via the shared
  /// line editor; null in headless.
  Future<bool> Function(String prompt, {String? body})? confirm;

  /// Detach the tmux client (`/detach`, Alt+D). Wired by the TUI coordinator,
  /// which owns the tmux process seam and all the messaging (detached notice,
  /// failure notice, "not in tmux" hint); null in headless, in which case
  /// `/detach` prints the "not in tmux" hint itself.
  Future<void> Function()? detachTmux;

  /// The in-tmux exit dialog (`/exit`/`/quit`, Ctrl+C×2, Ctrl+D, EOF). Wired
  /// by the TUI coordinator (it owns the overlay); null outside tmux or in
  /// headless, where exiting is immediate. See [TmuxExitChoice].
  Future<TmuxExitChoice> Function()? onTmuxExit;

  /// Auto-compact: when an incoming turn's estimated input tokens exceed this,
  /// summarize the older history first (keeping [autoCompactPreserveRecent]
  /// recent human turns). 0 disables. Mutable at runtime via /auto-compact.
  int _autoCompactThreshold;
  int get autoCompactThreshold => _autoCompactThreshold;
  set autoCompactThreshold(int value) {
    _autoCompactThreshold = value;
    turns.autoCompactThreshold = value;
  }

  /// How many recent human turns auto-compact leaves uncompressed.
  final int autoCompactPreserveRecent;

  /// The host environment (env vars + OS), so the controller doesn't read
  /// [Platform] directly. Defaults to the real platform.
  final Environment environment;

  /// The slash-command handlers, operating on this controller through the
  /// [CommandContext] seam. Lazy so it can capture `this`.
  late final SessionCommandHandlers _commands = SessionCommandHandlers(
    ControllerCommandAdapter(this),
  );

  /// Two-press Esc arming. Set to true on first Esc while a turn is running;
  /// the second Esc actually cancels. Cleared when the turn ends naturally.
  bool get _cancelArmed => inputState.cancelArmed;
  set _cancelArmed(bool value) => inputState.cancelArmed = value;

  /// The directory holding workflow `.dot` files. Wired by the TUI/headless
  /// runner; null when unavailable.
  Directory? workflowsDir;

  /// The `[default] workflow` config value: names the default workflow file
  /// shown by `/workflow list` (the seeded `default.dot` unless configured
  /// otherwise; `"none"` is explicit). Launched by the main agent's
  /// `launch_workflow` tool by default. Wired by the TUI coordinator; null when
  /// unset.
  String? defaultWorkflow;

  /// Open the visual graph viewer. Wired by the TUI.
  Future<void> Function(String name)? openWorkflowViewer;

  /// Open the visual node editor. Wired by the TUI.
  Future<void> Function({String? name, bool isNew})? openWorkflowEditor;

  /// Open the full-output viewer for a capped tool call (`/output`). Wired by
  /// the TUI; null in headless.
  Future<void> Function(int index)? openToolOutput;

  /// The process-wide token ledger (`/spend`). Wired by the composition root;
  /// used to persist usage into the active session's manifest.
  SpendLedger? spendLedger;

  final BackgroundJobSupervisor jobs = BackgroundJobSupervisor();
  late final ProjectBackgroundJobs background = ProjectBackgroundJobs(
    supervisor: jobs,
    summaryIndex: () => summaryIndex,
    persistUsage: _flushUsageFor,
    // The conversation's proven model ref: the live ref a `/model` swap
    // leaves on the conversation (kept in step with the persisted meta by
    // changeModel — and correct even when that write failed), else the
    // persisted meta ref, else the session's provider + the live model.
    modelRefOf: (conv) => conv.modelReference.isNotEmpty
        ? conv.modelReference
        : conv.recorder?.meta?.model ??
              '${sessionManager.active.providerId}/${conv.provider.model}',
  );
  bool get isIndexRunning => jobs.running('index');
  final Map<String, String> _environmentRequests = {};
  bool get isEnvironmentRunning => _environmentRequests.isNotEmpty;

  /// Submit to the session's main conversation, even when a child is focused.
  /// No new provider, host, job, or fixed scout population is created.
  Future<void> runEnvironment(Conversation source) async {
    final index = environmentIndex;
    if (index == null) return;
    final session = sessionManager.all.firstWhere(
      (s) => s.conversationById(source.id) != null,
    );
    final main = session.conversations.first;
    if (main.isClosed) return;
    if (sessionManager.activeId != session.id) switchSession(session.id);
    presentConversationSelection(sessionManager.selectConversation(main.id));
    onConversationFocusRequested?.call(main.id);
    if (_environmentRequests.containsKey(main.id)) {
      source.host.showMessage(
        'Environment setup is already queued or running in the main conversation.\n',
        style: HostMessageStyle.dim,
      );
      return;
    }
    // MessageQueue normalizes submissions; keep the same text as the key
    // used to recognize this task when a queued turn eventually starts.
    final prompt = index.taskPrompt().trim();
    _environmentRequests[main.id] = prompt;
    final submission = turns.submit(main.id, prompt);
    if (submission == TurnSubmission.rejected) {
      _environmentRequests.remove(main.id);
      return;
    }
    source.host.showMessage(
      submission == TurnSubmission.queued
          ? 'Environment setup queued in the main conversation.\n'
          : 'Environment setup started in the main conversation (Ctrl+C to cancel).\n',
      style: HostMessageStyle.dim,
    );
  }

  void Function(bool)? _beginEnvironmentTurn(
    Conversation conversation,
    String prompt,
  ) {
    if (_environmentRequests[conversation.id] != prompt) return null;
    final index = environmentIndex!;
    try {
      final before = index.beginVerification();
      return (completed) {
        _environmentRequests.remove(conversation.id);
        final updated = index.finishVerification(before, completed: completed);
        conversation.host.showMessage(
          updated
              ? 'Environment record updated (.tina/ENVIRONMENT.md).\n'
              : 'Environment record was not verified; setup remains incomplete.\n',
          style: updated ? HostMessageStyle.success : HostMessageStyle.warning,
        );
      };
    } catch (e) {
      _environmentRequests.remove(conversation.id);
      conversation.host.showMessage(
        'Environment verification unavailable: $e\n',
        style: HostMessageStyle.warning,
      );
      return null;
    }
  }

  Future<void> Function(Conversation, List<String>?, {bool repartition})?
  get runBackgroundIndex => background.runIndex;
  Future<void> Function()? shutdownWorkflows;
  Future<void>? _shutdown;
  Future<void> shutdown() => _shutdown ??= _stop();
  Future<void> _stop() async {
    final turnStop = turns.shutdown();
    final jobStop = jobs.shutdown();
    await Future.wait([
      turnStop,
      jobStop,
      if (shutdownWorkflows != null) shutdownWorkflows!(),
    ]);
    _environmentRequests.clear();
    await _flushUsage();
  }

  SessionController({
    required this.sessionManager,
    required this.readLine,
    this.sessionStore,
    this.exitSignal,
    this.onSessionsChanged,
    this.onActiveFocusChanged,
    int autoCompactThreshold = 0,
    this.autoCompactPreserveRecent = 2,
    this.environment = const PlatformEnvironment(),
  }) : _autoCompactThreshold = autoCompactThreshold;

  Conversation get active => sessionManager.activeConversation;

  /// The interactive input → turn loop. Always sits in [readLine]; agent turns
  /// run fire-and-forget per conversation, so the user can keep typing, switch
  /// sessions, or queue messages while a turn is in flight. Returns when [exitSignal]
  /// fires or input reaches EOF. ESC cancels the active conversation's turn
  /// (wired to [cancelActiveTurn] by the host).
  Future<void> run() async {
    try {
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
          // A quit attempt (Ctrl+C×2 / Ctrl+D / EOF): inside tmux this offers
          // Detach / Exit / Cancel before the process actually stops.
          final stay = await handleExitIntent();
          if (stay) continue;
          unawaited(_flushUsage()); // persist spend on quit
          return;
        }

        final trimmed = input.trim();
        if (trimmed.isEmpty) {
          // #31 interrupt gesture: Enter on an EMPTY input while a turn is
          // running and the queue holds work = "break into the run and process
          // what I typed". Completes the turn's tool-interrupt signal — the
          // in-flight tool batch finishes whole (in-flight result prefixed
          // "interrupted by operator — new input pending", later calls stub)
          // and the turn ends CLEANLY (distinct from Esc/Esc-Esc cancel,
          // which rolls back). Without queued work the keypress stays inert —
          // there is nothing to hand the run over TO; without a running turn
          // it also stays inert (an empty submit was a no-op before; Esc
          // still owns cancel).
          final s0 = active;
          final interrupt = s0.toolInterruptCompleter;
          if (s0.isRunning &&
              interrupt != null &&
              !interrupt.isCompleted &&
              s0.messageQueue.isNotEmpty) {
            turns.interruptTools(s0.id);
            s0.host.showMessage(
              'interrupting — queued input next\n',
              style: HostMessageStyle.dim,
            );
          }
          continue;
        }

        final target = active;
        final cmd = await _commands.dispatch(trimmed);
        if (cmd is CmdExit) {
          final stay = await handleExitIntent();
          if (stay) continue;
          unawaited(_flushUsage()); // persist spend on quit
          return;
        }
        if (cmd is CmdHandled) continue;
        if (cmd case CmdRun(:final prompt)) {
          // A command that injects a fixed prompt (e.g. /index): run it as a
          // normal turn with the prompt as the user input, not the raw command
          // word. Reuses the same turn path a typed line takes.
          final rs = target;
          if (rs.isRunning) {
            turns.submit(rs.id, prompt);
            rs.host.showMessage(
              '$trimmed  [queued — ${rs.messageQueue.length} pending]\n',
              style: HostMessageStyle.dim,
            );
          } else {
            _startTurn(rs, prompt);
          }
          continue;
        }

        // Plain text (or an unknown /command) goes to the active session.
        final s = target;
        if (s.isRunning) {
          turns.submit(s.id, trimmed);
          s.host.showMessage(
            '$trimmed  [queued — ${s.messageQueue.length} pending]\n',
            style: HostMessageStyle.dim,
          );
        } else {
          _startTurn(s, trimmed);
        }
      }
    } finally {
      await shutdown();
    }
  }

  /// An exit intent: `/exit`/`/quit` (a [CmdExit]) or a null readLine (Ctrl+C×2,
  /// Ctrl+D, or EOF). Returns TRUE when the REPL should keep running (the user
  /// cancelled, or chose Detach in tmux — the process stays alive either way),
  /// FALSE when it should return (exit). Outside tmux (or headless, where
  /// [onTmuxExit] is null) this is immediate — no dialog, exit as today.
  /// Public (not private) so the tmux exit paths are unit-testable in
  /// isolation without driving the whole REPL loop.
  Future<bool> handleExitIntent() async {
    final onExit = onTmuxExit;
    if (onExit == null) return false;
    final choice = await onExit();
    if (choice == TmuxExitChoice.detach) {
      // The dialog is tmux-only, so the detach closure (which owns the
      // detached/failed messaging) is wired. Runs best-effort — a failed
      // detach warns and keeps the session running; the user can retry.
      final detach = detachTmux;
      if (detach != null) {
        try {
          await detach();
        } catch (e) {
          // Defensive: the real closure swallows spawn errors itself, but a
          // throwing closure must never block the exit decision.
          active.host.showMessage(
            'detach failed: $e\n',
            style: HostMessageStyle.dim,
          );
        }
      }
      return true;
    }
    return choice != TmuxExitChoice.exit;
  }

  /// ESC handler: cancel the active conversation's in-flight turn, or a
  /// background `/index` fleet run when no turn is running. Returns true
  /// (handled) when something was running and was signalled, so the line editor
  /// consumes the Esc instead of falling through to its own Esc handling; false
  /// when nothing was running (the editor then activates the menu bar).
  bool cancelActiveTurn() {
    final s = active;
    if (s.cancelCompleter?.isCompleted == true) {
      _cancelArmed = false;
      return true;
    }
    if (!s.isRunning) {
      // No turn, but a background index run may be cancellable.
      if (isIndexRunning) {
        if (!_cancelArmed) {
          _cancelArmed = true;
          s.host.showMessage(
            'Press Esc again to cancel the background run\n',
            style: HostMessageStyle.warning,
          );
          return true;
        }
        _cancelArmed = false;
        jobs.cancelAll();
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
    final c = s.cancelCompleter;
    if (c != null && !c.isCompleted) {
      if (!turns.cancel(s.id)) c.complete();
    }
    return true;
  }

  /// Cancel the active conversation and background index work immediately.
  /// Used by Ctrl+C and rapid Esc-Esc, including across approval prompts.
  /// Returns false when idle so input clearing and quit behavior still work.
  bool cancelNow() {
    final s = active;
    _cancelArmed = false;
    // Background index jobs cancel INDEPENDENTLY of the
    // conversation's turn: a concurrent proposal turn must not shield a
    // doomed fleet from the operator's Esc-Esc.
    var hit = false;
    if (isIndexRunning) {
      jobs.cancelAll();
      hit = true;
    }
    if (!s.isRunning) return hit;
    final c = s.cancelCompleter;
    if (c != null && !c.isCompleted) {
      if (!turns.cancel(s.id)) c.complete();
      hit = true;
    }
    return hit;
  }

  // -- Turn execution facade ----------------------------------------------
  late final TurnExecutor turns = TurnExecutor(
    findConversation: _findConversation,
    environment: environment,
    autoCompactThreshold: autoCompactThreshold,
    autoCompactPreserveRecent: autoCompactPreserveRecent,
    onChanged: () {
      inputState.resetEscape();
      onSessionsChanged?.call();
    },
    persistUsage: (conversation) => _flushUsageFor(conversation),
    onTurnStarted: _beginEnvironmentTurn,
    toolsForTurn: (conversation, prompt) =>
        _environmentRequests[conversation.id] == prompt
        ? EnvironmentToolStage(conversation.agent.tools)
        : null,
  );
  void _startTurn(Conversation conversation, String input) =>
      turns.submit(conversation.id, input);
  Future<void> _flushUsageFor(Conversation conversation) async {
    for (final session in sessionManager.all) {
      if (identical(session.conversationById(conversation.id), conversation)) {
        await _flushUsage(session.id);
        return;
      }
    }
  }

  /// Persist the ledger's current total into the active session's manifest
  /// (`/spend` restore on resume). Best-effort: a failed write must never
  /// break the turn.
  Future<void> _flushUsage([String? sessionId]) async {
    final ledger = spendLedger;
    final store = sessionStore;
    if (ledger == null || store == null) return;
    final sid = sessionId ?? sessionManager.activeId;
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
  void injectWorkflowResult(WorkflowRun run) => turns.injectWorkflowResult(run);

  /// The conversation with id [conversationId] across every session, or null
  /// when it no longer exists (closed/deleted).
  Conversation? _findConversation(String conversationId) {
    for (final session in sessionManager.all) {
      final conv = session.conversationById(conversationId);
      if (conv != null) return conv;
    }
    return null;
  }

  // -- Session management (also driven by the View menu) ------------------

  /// Create a new session and switch to it.
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
      style: HostMessageStyle.dim,
    );
    onSessionsChanged?.call();
    onActiveFocusChanged?.call();
  }

  /// Switch to an existing session by id.
  void switchSession(String id) {
    if (id == sessionManager.activeId) return;
    final fromId = sessionManager.activeId;
    // Persist the outgoing session's spend, then restore the incoming
    // session's recorded spend into the ledger.
    unawaited(_flushUsage());
    presentConversationSelection(sessionManager.selectSession(id));
    _seedUsageFrom(id);
    _swapInput(fromId, id);
    active.host.showMessage(
      '(switched to ${_shortId(id)} — ${active.provider.model})\n',
      style: HostMessageStyle.dim,
    );
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
      if (saved != null) inputState.drafts[fromId] = saved;
    }
    final incoming = inputState.drafts.remove(toId);
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
      s.host.showMessage(
        '(persistence disabled — cannot resume)\n',
        style: HostMessageStyle.dim,
      );
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
    s.host.showMessage(
      'resumed: $id (${loaded.length} messages)\n',
      style: HostMessageStyle.dim,
    );
    return true;
  }

  static String _shortId(String id) =>
      id.length > 6 ? id.substring(id.length - 6) : id;
}
