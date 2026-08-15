import 'dart:async';
import 'dart:io';

import 'package:tina_engine/tina_engine.dart';

import '../conversation.dart';
import '../environment/environment_index.dart';
import '../session_manager.dart';
import '../summaries/summary_index.dart';

/// The dispatch result of [SessionCommandHandlers.dispatch]. The input wasn't a
/// command ([CmdNotCommand] — pass it through to the agent), a command was
/// handled ([CmdHandled] — continue the input loop), `/exit` was invoked
/// ([CmdExit] — return from the loop), or the command produced a prompt
/// ([CmdRun]) the caller should execute as a normal agent turn.
///
/// [CmdRun] is the seam for commands like `/index` that don't do their own work
/// but inject a fixed user prompt into the conversation — the controller runs it
/// through the same turn path a typed line takes (echo, auto-compact,
/// persistence, cancel), so the command needs no separate machinery.
sealed class CmdResult {
  const CmdResult();
}

class CmdNotCommand extends CmdResult {
  const CmdNotCommand();
}

class CmdHandled extends CmdResult {
  const CmdHandled();
}

class CmdExit extends CmdResult {
  const CmdExit();
}

/// Run a normal agent turn with [prompt] as the user input. The raw command
/// word is discarded; [prompt] is what the agent sees and what's persisted.
class CmdRun extends CmdResult {
  const CmdRun(this.prompt);
  final String prompt;
}

/// The slice of [SessionController] the slash-command handlers operate on.
/// Exposing it as an interface lets the handlers live in their own module and
/// be exercised against a fake, without standing up the input loop or a host.
/// [SessionController] implements this with its own public fields and methods.
abstract class CommandContext {
  /// The active conversation — handlers read/write its history, host, policy,
  /// recorder, and provider.
  Conversation get active;

  /// Live (in-memory) sessions, for `/session list|switch|close` and the
  /// running-state checks.
  SessionManager get sessionManager;

  /// On-disk sessions, for `/sessions` and `/resume`. Null when persistence is
  /// disabled.
  SessionStore? get sessionStore;

  /// Auto-compact threshold (tokens); 0 disables. `/auto-compact` reads/sets it.
  int get autoCompactThreshold;
  set autoCompactThreshold(int value);

  /// How many recent human turns auto-compact leaves uncompressed.
  int get autoCompactPreserveRecent;

  /// Pre-command hooks keyed by word (e.g. `/clear`), awaited before the
  /// default handler.
  Map<String, FutureOr<void> Function()> get commandHooks;

  /// Fired when sessions/active change, so a host can refresh a session menu.
  void Function()? get onSessionsChanged;

  /// Open the first-run/setup overlay pre-filled with the current config
  /// (`/settings`). Wired by the TUI; null in headless (no overlay available).
  Future<void> Function()? get openSettings;

  /// Open the system-prompt editor overlay (`/prompts`). Wired by the TUI;
  /// null in headless (no overlay available).
  Future<void> Function()? get openPrompts;

  /// Open the spawn overlay (`/spawn`) to pick a model and start a sub-agent.
  /// Wired by the TUI; null in headless (no overlay available).
  Future<void> Function()? get openSpawn;

  /// Open the branch overlay (`/branch`) to fork the active conversation into a
  /// new side panel, copying its history. Wired by the TUI; null in headless.
  Future<void> Function()? get openBranch;

  /// Open the model-picker overlay (`/model`) to switch the active
  /// conversation's provider/model. Wired by the TUI; null in headless.
  Future<void> Function()? get openModelPicker;

  /// Open the session-picker overlay (Alt+S or `/session switch` with no arg)
  /// to switch to or resume a session. Wired by the TUI; null in headless.
  Future<void> Function()? get openSessionPicker;

  /// Display the image at [path] in the focused panel (`/image`). Wired by the
  /// TUI; null in headless (no surface to render onto).
  Future<void> Function(String path)? get openImage;

  /// The per-directory summary sidecar service (`/index`). Its [SummaryIndex.status]
  /// is a pure-git staleness probe (no LLM); [SummaryIndex.refresh] runs the
  /// summarizer fleet. Wired by the TUI and the headless path from the live
  /// [AppComposition] (config/registry/environment); null when no composition is
  /// available, in which case `/index` falls back to an ad-hoc in-chat review.
  SummaryIndex? get summaryIndex;

  /// The environment agent service (first load + the `/index` dance's
  /// environment branch). Wired by the TUI from the live [AppComposition];
  /// null in headless, which never auto-runs setup.
  EnvironmentIndex? get environmentIndex;

  /// Ask a yes/no confirmation, returning true on "y". Wired by the TUI via the
  /// shared line editor's single-keystroke read (the same primitive the
  /// permission modal uses); null in headless (no interactive input), where the
  /// `/index` up-to-date branch simply reports and stops.
  Future<bool> Function(String prompt)? get confirm;

  /// Create a new session and switch to it (`/session new`).
  Future<void> newSession({String? providerId, String? model});

  /// Switch to an existing session by id (`/session switch`).
  void switchSession(String id);

  /// Load a saved session from disk into the active conversation (`/resume`
  /// and the session picker). Returns true on success.
  Future<bool> resumeIntoActive(String id);

  /// The directory holding workflow `.dot` files (`~/.tina/workflows`). Null
  /// when workflows aren't configured. Read by `/workflow list|show`.
  Directory? get workflowsDir;

  /// The `[default] workflow` config value (`"none"` = explicit, a name =
  /// explicit, null/empty = the conventional `default.dot`). Null when the
  /// config sets nothing. Names the default workflow file shown by `/workflow
  /// list` and launched by the main agent's `launch_workflow` tool by default.
  String? get defaultWorkflow;

  /// Open the visual graph viewer for a saved workflow (`/workflow show`).
  /// Wired by the TUI; null in headless (no screen).
  Future<void> Function(String name)? get openWorkflowViewer;

  /// Open the full-output viewer for a capped tool call (`/output`).
  /// [index] is 0-based, newest first, against the active conversation's
  /// capped-output ring. Wired by the TUI; null in headless (no screen).
  Future<void> Function(int index)? get openToolOutput;

  /// The process-wide token ledger (`/spend`). Wired by the composition root;
  /// null when no composition exists (headless without one).
  SpendLedger? get spendLedger;

  /// Launch the summary fleet as a background task on [conv] (`/index` in the
  /// TUI): the prompt returns immediately, fleet output streams into the
  /// conversation's host, and ESC cancels. Wired by the TUI's
  /// [SessionController]; null in headless (which runs the fleet inline).
  Future<void> Function(Conversation conv, List<String>? dirs,
      {bool repartition})? get runBackgroundIndex;

  /// Launch the environment agent as a background task on [conv] (the `/index`
  /// dance's environment branch, and first load): returns immediately, the
  /// agent's output streams into the conversation's host, and ESC cancels.
  /// Wired by the TUI's [SessionController]; null in headless, which never
  /// auto-runs setup.
  Future<void> Function(Conversation conv)? get runBackgroundEnvironment;

  /// Open the visual node editor (`/workflow new` / `/workflow edit`). Wired by
  /// the TUI; null in headless.
  Future<void> Function({String? name, bool isNew})? get openWorkflowEditor;
}
