# Plan: non-blocking workflow launch + auto agent turn on completion

## Context

The just-completed work made `launch_workflow` a **blocking** tool — the agent's
turn held open for the whole run and got the outcome back in-turn. Walking
through a clean session exposed the cost: a multi-minute workflow **ties up the
conversation** for its entire duration (the user can only *queue* a follow-up,
not get a reply). The user decided the conversation must not block, and chose
**auto agent turn on completion** — when a background run finishes, the agent is
woken with a synthetic turn carrying the outcome so it reports/acts on it.

So: the launch becomes **fire-and-forget** again, the run churns in the
background while the chat stays open, and completion **injects an agent turn**.
This re-introduces active-run tracking (a supervisor) — but launched by the
agent's tool (not a slash command), with a new completion→turn path the old
supervisor lacked, and a `stop_workflow` agent tool mirroring launch.

The prompt also currently *describes* the blocking model ("runs to completion
and returns the outcome to you") — that sentence is now false and must change.

## Approach

### 1. Restore + adapt the supervisor — `lib/pipeline/workflow_supervisor.dart`

Restore from `git show HEAD:lib/pipeline/workflow_supervisor.dart` (the deleted
file) and adapt:

- **Move `RunWorkflow` typedef here** (its original home; the tool + coordinator
  import it from here). Same signature as today
  (`{required workflowName, required sink, input, history, cancelSignal}`).
- `launch({required String name, required String conversationId, required AgentSink sink, String? input, String? goal})`:
  - Adds **`conversationId`** (stored on the run, used to route the completion
    turn back to the conversation that launched it).
  - Drops the `List<Message>? history` param (the agent now crafts `input`; the
    runner's `history` arg stays, passed `null`).
  - Fire-and-forget as before: builds a per-run cancel `Completer`, calls `_run`
    detached, returns a `WorkflowRun` handle immediately.
  - In the completion `.then`: set `run.outcome`/`status` via `_classify`, call
    `_reportBack(sink, run)` (the immediate `✔/✖` notice), then call
    **`onComplete?.call(run)`**.
- `WorkflowRun`: add `final String conversationId;`. Keep `id`, `workflowName`,
  `goal`, `input`, `_cancel`, `status`, `outcome`, `isRunning`.
- Constructor takes `void Function(WorkflowRun)? onComplete` (the hook the
  coordinator wires to the controller's inject method).
- Keep `stop([id])`, `stopAll()`, `active`, `find(id)`, `_mostRecentActive()`,
  `_classify()`, `_reportBack()`, `_newId()` unchanged.

### 2. Rewrite the launch tool (non-blocking) + add a stop tool — `lib/pipeline/launch_workflow_tool.dart`

- **`LaunchWorkflowTool`**: constructor
  `({required WorkflowSupervisor supervisor, required String conversationId, required AgentSink sink})`.
  `execute` validates `input`, defaults `workflow`, calls
  `supervisor.launch(name: workflow, conversationId: conversationId, sink: sink, input: task)`,
  and returns **immediately** with a result like
  `Launched workflow "default" in the background (run 3). It runs to completion while the chat stays open; I'll report back with the result when it finishes. Cancel it with stop_workflow.`
  No `await` on the run; `cancelSignal` is unused (the launching turn ends).
- **`StopWorkflowTool`** (new, same file): schema `stop_workflow`, optional
  `{ run_id: string }`; `execute` → `supervisor.stop(id)` → result
  "stopped run …" / "no running workflow to stop". Mirrors the old
  `/workflow stop` as an agent tool.
- `RunWorkflow` typedef now lives in the supervisor file; update imports in
  `agent_composition.dart` + tests.

### 3. Composition — `lib/composition/agent_composition.dart`

- Change `buildAgent` param `RunWorkflow? launchWorkflow` →
  `WorkflowSupervisor? supervisor`.
- When wired: add both `LaunchWorkflowTool(supervisor, conversationId, host)`
  and `StopWorkflowTool(supervisor)` to the shared base tool list (both modes).
- Widen `mainPolicy.defaults` to `allow` `stop_workflow` (same treatment as the
  channel tools / `launch_workflow`).
- Update the doc comment (no longer "blocking; awaits the run").

### 4. Completion → agent turn — `lib/session_controller.dart`

Add a public inject method that reuses the existing turn machinery
(`_startTurn` / `messageQueue` enqueue-or-start, mirroring `run()` lines 221-228):

```dart
void injectWorkflowResult(WorkflowRun run) {
  if (run.status == WorkflowRunStatus.cancelled) return; // agent/user initiated
  final conv = _findConversation(run.conversationId);
  if (conv == null) return;                              // conversation closed
  final prompt = _workflowOutcomePrompt(run);
  if (conv.isRunning) {
    conv.messageQueue.enqueue(prompt);                   // drained at end of _runTurn
    conv.host.showMessage('[workflow "${run.workflowName}" finished — result queued]\n',
        style: HostMessageStyle.dim);
  } else {
    _startTurn(conv, prompt);                            // wakes the agent now
  }
}
```

- `_findConversation(id)`: iterate `sessionManager.all` →
  `session.conversationById(id)` (the only lookup path).
- `_workflowOutcomePrompt(run)`: a synthetic user-role string handing the agent
  the outcome — completed → "…finished successfully: <notes>. Report the outcome
  and act if anything remains."; failed → "…failed: <reason>. Report and decide
  on a fix."; (cancelled → unreachable, guarded above). Goes through `_runTurn`,
  so it's echoed, persisted, and activity-managed like any turn.
- The **only** new public entrypoint; no existing turn path changes.
- Imports `package:tina/pipeline/workflow_supervisor.dart`.

### 5. Coordinator wiring — `lib/tui_coordinator.dart`

Reuse the **`handleBackgroundActivity` late-field pattern** (a coordinator field
that's `null` until the controller exists; closures capture it and read at call
time — the established solution to agent-built-before-controller ordering, lines
335/406 capture vs 554 assign):

- Add field `void Function(WorkflowRun)? handleWorkflowComplete;`.
- Replace the current `RunWorkflow launchWorkflow` block (~354-371) with:
  ```dart
  final supervisor = WorkflowSupervisor(
    run: ({required workflowName, required sink, input, history, cancelSignal}) =>
        buildRunner().run(workflowName: workflowName, sink: sink,
            input: input, history: history, cancelSignal: cancelSignal),
    onComplete: (run) => handleWorkflowComplete?.call(run),
  );
  ```
  Keep `buildRunner()` as-is.
- Change both `buildAgent(...)` call sites (initial ~408, agentBuilder ~445):
  `launchWorkflow: launchWorkflow` → `supervisor: supervisor`.
- After the controller is constructed (~716, alongside
  `controller.workflowsDir = …`): `handleWorkflowComplete = controller.injectWorkflowResult;`

### 6. Prompt — `packages/tina_engine/lib/src/agent/agent_pipeline.dart`

Rewrite the launch bullet in `_mainIdentity` (keep literal `coding assistant`;
keep the sub-agent inheritance clause). New shape: launch is **non-blocking** —
returns immediately with a run id and the workflow runs in the background; node
progress streams into the chat; when it finishes you receive a follow-up turn
with the outcome, at which point report to the user and act on it (summarize,
fix, follow up). Cancel a running workflow with `stop_workflow`. Direct file
tools for small changes; `delegate` for one focused sub-task.

### 7. Docs

- `docs/features/manager_loop.md` §3/§4/§6: launch is **non-blocking** again
  (supervisor restored, agent-launched not slash-command); completion injects an
  agent turn via `controller.injectWorkflowResult`; `stop_workflow` tool; ESC no
  longer cancels (use the tool). Note the chat stays open during a run.
- `docs/features/default_workflow.md` "Run" line: non-blocking launch + auto
  report-back turn (the "blocking"/"returns the outcome" wording is gone).
- `bin/tina.dart` seed message already says "launches via its launch_workflow
  tool" — fine; no blocking claim to fix.

## Files

- **Restore + edit:** `lib/pipeline/workflow_supervisor.dart` (from git HEAD, +`conversationId`, +`onComplete`).
- **Rewrite:** `lib/pipeline/launch_workflow_tool.dart` (non-blocking `LaunchWorkflowTool` + new `StopWorkflowTool`; `RunWorkflow` typedef moves to supervisor).
- **Edit:** `lib/composition/agent_composition.dart` (`supervisor` param; both tools; policy), `lib/tui_coordinator.dart` (supervisor + late `handleWorkflowComplete`), `lib/session_controller.dart` (`injectWorkflowResult` + helpers), `packages/tina_engine/lib/src/agent/agent_pipeline.dart` (`_mainIdentity`), `docs/features/manager_loop.md`, `docs/features/default_workflow.md`.
- **Tests:** restore `test/workflow_supervisor_test.dart` (adapt: `conversationId`, `onComplete`, drop `goal`/`history` assertions); rewrite `test/pipeline/launch_workflow_tool_test.dart` (non-blocking return + a `stop_workflow` assertion); new controller group for `injectWorkflowResult` (idle → starts a turn; busy → enqueues; cancelled → no-op) in `test/session_controller_test.dart`.

## Reused machinery

- `WorkflowSupervisor`/`WorkflowRun` (git HEAD) — the fire-and-forget lifecycle, stop/stopAll, completion classification + report notices.
- `PipelineRunner.run` (`lib/pipeline/pipeline_runner.dart`) — the run seam, unchanged; `onEvent`→`_renderEvent` already streams `▶/✔/✖` notices to the sink.
- `_startTurn`/`_runTurn` + `Conversation.messageQueue` drain (`session_controller.dart`) — the inject method reuses the existing turn path verbatim (echo, persist, activity, queue drain).
- `handleBackgroundActivity` late-field pattern (`tui_coordinator.dart`) — solves supervisor-captures-controller-before-it-exists.

## Verification

1. `dart test test/workflow_supervisor_test.dart` — launch returns immediately with a running handle; monitoring surfaces to sink; complete/fail/cancel report back and fire `onComplete`; stop/stopAll/`stop(id)` behave.
2. `dart test test/pipeline/launch_workflow_tool_test.dart` — `launch_workflow` returns immediately (does not await the run) with a "launched … run <id>" result and forwards `input`/`workflow`/`conversationId`; `stop_workflow` cancels.
3. `dart test test/session_controller_test.dart` (new group) — `injectWorkflowResult` on an idle conversation starts a turn the agent runs; on a running conversation enqueues (drained after); on `cancelled` is a no-op; on a missing conversation is a no-op.
4. `dart test packages/tina_engine/test/agent/system_prompt_test.dart` — green (keeps `coding assistant`).
5. `dart test` full suite + `dart analyze` (touched files) + `test/import_boundary_test.dart` — supervisor is app-layer, no boundary crossing.
6. Manual (TUI): clean session, ask for a multi-step change → agent calls `launch_workflow`, **the chat stays open** (type a question mid-run → it answers), node notices stream, and on completion the agent spontaneously reports/acts on the outcome; ask to cancel mid-run → agent calls `stop_workflow` and the run aborts.
