/// One plugin interface for session lifecycle and turn phases. Turn phases
/// receive a `TurnContext` and assign what they want to change.
library;

import 'dart:async';
import 'package:tina_core/tina_core.dart';

import 'context.dart';
import 'loop.dart';
import 'model.dart';

/// A plugin. The core owns truth; the plugin owns decisions, made by
/// writing to the [TurnContext] it is handed.
///
/// ## Ordering
///
/// Hooks run sequentially in ascending [order], ties broken by [id]; the
/// loop awaits each hook before the next starts. Every phase accepts
/// `FutureOr`, so existing synchronous overrides keep working unchanged.
/// Closing runs in reverse.
///
/// ## The copy rule and its boundary
///
/// The loop copies the context before each turn phase and keeps the copy
/// the phase wrote. A phase that fails has its copy discarded, so its
/// *context* writes are dropped. The copy is shallow at the payload
/// boundary: `messages`, `promptSections` and `pinnedTools` are new lists
/// of the same immutable-by-convention element references, and the
/// cancellation token is shared — cancelling rolls through every copy, and
/// dropping a copy does not roll a cancel back. Plugin code must treat
/// payload objects (`Message`, content blocks, `ToolSchema`, their nested
/// lists and maps) as immutable: a plugin that mutates a shared payload in
/// place affects the turn whether its copy is kept or not, and the loop
/// cannot roll that back.
///
/// ## Failure contract
///
/// Enforcement hooks fail closed: an unexpected exception is never
/// permission. The consequence is per phase (each hook documents its own);
/// the loop reports every failure as a [HookFailure] on the loop's
/// `hookFailures` list and keeps error text out of prompts and tool
/// results by default. A plugin doing optional observational work catches
/// its own failures and reports unavailability instead of throwing —
/// classification is the model to copy. Session lifecycle failures
/// (`openSession`, `sessionChanged`, `closeSession`, `mountOn`) propagate
/// to the host for resource cleanup; they are not phase failures.
abstract class AgentPlugin {
  /// Const: plugins are value-like config and can be const-constructed.
  const AgentPlugin();

  /// Lowercase publisher/name. The application reserves tina/ for first-party
  /// plugins. Duplicate IDs throw. Also the tie-breaker for [order].
  String get id;

  /// Ascending everywhere. Lower runs first.
  int get order => 100;

  /// Tools contributed to the loop. Snapshotted once per turn.
  List<ToolSchema> get tools => const [];

  /// Finish asynchronous discovery before this turn's tool set is pinned.
  /// Changes from external notifications are applied here, never mid-turn.
  /// The usual cancellation and fail-closed hook rules apply.
  FutureOr<void> prepareTurn(TurnContext context) {}

  /// Prepare session resources before constructing the loop. A plugin may
  /// return the restored transcript and details when resuming.
  SessionSeed? openSession(PluginSession session) => null;

  /// Persist or react to changes in the shared session metadata.
  void sessionChanged(PluginSession session) {}

  /// Release resources, including partially opened resources after a failure.
  void closeSession() {}

  /// Mount executors and subscribe to this session. Called once by the host.
  void mountOn(AgentLoop loop) {}

  /// Commands collected by the host; the loop does not dispatch them.
  List<Command> get commands => const [];

  /// Prompt section phase, before the turn: add a section to
  /// `c.promptSections`, or add nothing. The core owns the join; a plugin
  /// adds one section, never a whole prompt.
  ///
  /// On an unexpected exception the turn ends as an error **before any
  /// model request** — a request must not be sent with required
  /// instructions silently missing. No user message is accepted yet.
  FutureOr<void> onPrompt(TurnContext c) {}

  /// Before recording a user message: rewrite `c.input`, or await a check
  /// and cancel the turn. Cancellation interrupts a pending hook; late
  /// writes to its copied context are discarded. Guards must cancel on
  /// their own errors.
  ///
  /// On an unexpected exception the turn stops **before the user message
  /// is recorded and before the provider is called**. The raw
  /// `input_recorded` audit entry stays — what the user typed is already
  /// in the log — but no accepted user message enters the transcript and
  /// no request is sent.
  FutureOr<void> onInput(TurnContext c) {}

  /// Before each model call: `c.messages`, `c.promptSections` and
  /// `c.pinnedTools` are the request about to be built.
  ///
  /// On an unexpected exception the request is **not sent**; the turn ends
  /// as an error before this call.
  FutureOr<void> beforeModelCall(TurnContext c) {}

  /// The guard: all must pass. Set `c.decision` to deny; the default is
  /// already allow. The first non-allow decision stands — later guards
  /// cannot overwrite it and, once decided, do not run.
  ///
  /// On an unexpected exception the guarded tool **never executes**: an
  /// error result is recorded for it, later calls in the same response are
  /// not dispatched, and every already-recorded call in the batch keeps a
  /// matching result. Failing closed is the whole point of a guard.
  FutureOr<void> beforeToolCall(TurnContext c) {}

  /// After a tool ran: `c.toolResult` is what the executor returned;
  /// assign it to record a different result.
  ///
  /// On an unexpected exception the already-executed tool is **never
  /// retried**, and the result is not silently exposed as if the required
  /// transformation had happened: a conservative error result is recorded
  /// instead, later calls in the batch are not dispatched, and pairing is
  /// preserved. External side effects have happened once; saying "error"
  /// is safer than laundering the result.
  FutureOr<void> afterToolResult(TurnContext c) {}

  /// The turn ended: `c.outcome` is what the turn produced. The outcome is
  /// already committed to the log when this phase runs.
  ///
  /// On an unexpected exception the failure is reported on the loop's
  /// `hookFailures` list and the remaining completion hooks still run.
  /// No second turn-end entry is appended and the turn is not rerun; the
  /// thrown error is absorbed here by design — the turn is over either
  /// way, and one plugin's cleanup bug must not hide the outcome from the
  /// others.
  FutureOr<void> onTurnEnd(TurnContext c) {}
}
