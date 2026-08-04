import 'dart:async';

import 'package:tina_engine/tina_engine.dart';

import 'conversation.dart';
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
        return;
      }

      final trimmed = input.trim();
      if (trimmed.isEmpty) continue;

      final cmd = await _commands.dispatch(trimmed);
      if (cmd is CmdExit) return;
      if (cmd is CmdHandled) continue;
      if (cmd case CmdRun(:final prompt)) {
        // A command that injects a fixed prompt (e.g. /index): run it as a
        // normal turn with the prompt as the user input, not the raw command
        // word. Reuses the same turn path a typed line takes.
        final rs = active;
        if (rs.isRunning) {
          rs.messageQueue.enqueue(prompt);
          active.host.showMessage(
              '$trimmed  [queued - ${rs.messageQueue.length} pending]\n',
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

  /// ESC handler: cancel the active conversation's in-flight turn. Returns true
  /// (handled) when a turn was running and was signalled, so the line editor
  /// consumes the Esc instead of falling through to its own Esc handling; false
  /// when nothing was running (the editor then activates the menu bar).
  bool cancelActiveTurn() {
    final s = active;
    if (!s.isRunning) {
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

    // Continue the session's backlog, if any.
    final next = s.messageQueue.dequeue();
    if (next != null) _startTurn(s, next);
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
    final s = await sessionManager.createSession(
      providerId: providerId,
      model: model,
    );
    sessionManager.switchSession(s.id);
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
    sessionManager.switchSession(id);
    active.host.showMessage(
        '(switched to ${_shortId(id)} — ${active.provider.model})\n',
        style: HostMessageStyle.dim);
    onSessionsChanged?.call();
    onActiveFocusChanged?.call();
  }

  static String _shortId(String id) =>
      id.length > 6 ? id.substring(id.length - 6) : id;
}
