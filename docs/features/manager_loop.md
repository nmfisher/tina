# The manager loop — the main agent runs workflows as child runs

**Status:** Implemented (this branch)
**Date:** 2026-08-08

## 1. The change in one paragraph

The main agent **moved outside the workflow**. The chat conversation is now the
persistent top-level context — it runs its own turns like any plain agent. A DOT
workflow is no longer wrapped around every chat turn. Instead, the main agent
**launches** a workflow as a **child run** when it wants one, **monitors** it
while it runs in the background, can **stop** it at any point, and gets a
**report** back when it finishes. The seeded `default.dot` stays as the
launchable default graph.

This is the **manager loop pattern**. In the attractor vocabulary a `house`-shaped
node maps to the `stack.manager_loop` handler type
(`packages/attractor/lib/src/graph.dart:219`): a supervisor that **observes,
steers, and waits** over a child pipeline. Here the supervisor is the main-agent
conversation; the child pipeline is a workflow run.

> Why "manager loop" and not a node? A house node would put the supervisor
> *inside* the graph. We do the opposite: the supervisor (the chat) sits
> *outside* the graph and treats the whole graph as one child it can launch and
> stop. The shape→type mapping names the pattern; the main agent lives it.

## 2. Before and after

### Before (v0.1.3)

Every normal chat turn was routed through the DOT workflow while
`~/.tina/workflows/default.dot` existed (`resolveDefaultWorkflowName` in
`lib/pipeline/default_workflow.dart:60`). The "main agent" was a node *inside*
that graph. The turn blocked until the whole graph (`main → plan → review →
fan-out → exec → done`) finished.

Routing lived in `SessionController._runTurn`
(`lib/session_controller.dart`): it resolved the default workflow and called
`runPipelineTurn` instead of the plain agent.

### After (this branch)

- **Normal turns run the plain agent.** `_runTurn` no longer consults the default
  workflow. The chat is the top-level loop.
- **A workflow is a child run.** The main agent launches one with `/workflow run
  <name> [input]`. The launch returns immediately — the run churns in the
  background — and the chat keeps accepting turns.
- **The seeded `default.dot` stays**, now as the launchable default graph
  (`/workflow run default`).

## 3. The four manager-loop operations

The main agent can do four things with a child workflow. The first three are the
ones the task names; the fourth is how the run ends.

### 3.1 Launch (goal + input)

`/workflow run <name> [input]` hands the request to a `WorkflowSupervisor`
(`lib/pipeline/workflow_supervisor.dart`) — the object that plays the manager
loop. The supervisor:

1. Creates a per-run cancel `Completer<void>`.
2. Calls the runner seam (`PipelineRunner.run`, wired as `runPipelineTurn`) as a
   fire-and-forget `Future`, passing the **active conversation's host as the
   sink** and the cancel completer's future as the `cancelSignal`.
3. Returns a `WorkflowRun` handle (id, workflow name, status, outcome).

`launch` takes a **goal** and an **input**:

- **`input`** is the task text. It flows into the run context as `context.input`
  and is expandable as `$input` in node prompts — exactly as a routed turn used
  to do.
- **`goal`** is a per-launch annotation of the run's purpose, surfaced in the
  launch and report notices. It does **not** override the graph's own
  `graph [goal="..."]`; nodes still see the graph goal as `$goal`. (Wiring a
  launch goal as a `$goal` override is future work.)

The slash command supplies `input` from its arguments. The `goal` parameter is
part of the `launch` API for richer callers (a future agent tool).

### 3.2 Monitor (events surface to chat, live)

The pipeline engine already emits progress events — `node_started`,
`node_completed`, `node_failed`, `node_retrying`, `started`, `completed`,
`failed` (`packages/attractor/lib/src/engine.dart:7`, rendered by
`PipelineRunner._renderEvent` at `lib/pipeline/pipeline_runner.dart:111`). Because
the supervisor passes the active host as the run's sink, **those events surface
to the chat as notices while the run is in flight** — `▶ node`, `✔ node`,
`✖ node: reason`. The streamed node text lands in the same chat. No polling is
needed: the events are pushed as they happen.

### 3.3 Stop (cancel at any point)

The engine already aborts a node when its `cancelSignal` future completes: the
handler throws `Aborted`, caught and turned into `Outcome.fail('cancelled')`
(`packages/attractor/lib/src/engine.dart:175`, `:43`). The supervisor holds each
run's cancel `Completer`. `/workflow stop [id]` completes it, which makes the
next handler call abort. The run then finishes with a `cancelled` outcome and
reports back (3.4). With no `id`, the most recent still-running launch is
stopped. `stopAll()` cancels every active run (used on shutdown).

### 3.4 Report back (and resume normal chat)

When the background run's `Future<Outcome>` completes — success, failure, or
cancellation — the supervisor posts one final notice to the host:

- success → `✔ workflow complete: <name>`
- failure → `✖ workflow failed: <name>: <reason>`
- cancelled → `✖ workflow cancelled: <name>`

The chat never blocked: the user could keep typing the whole time. The report
notice is how the run "reports back." The main agent can then act on the result
in a later turn.

## 4. The `WorkflowSupervisor` API

```dart
class WorkflowSupervisor {
  WorkflowSupervisor({required RunWorkflow run});

  /// Launch <name> as a background child run. Output + events stream to [sink].
  /// Returns immediately with a handle. [goal] annotates the run; [input] flows
  /// in as $input; [history] (if given) is seeded as $history.
  WorkflowRun launch({
    required String name,
    required AgentSink sink,
    String? input,
    String? history,
    String? goal,
  });

  /// Cancel the run [id] (or the most recent active run when null). Returns true
  /// when a running run was signalled.
  bool stop([String? id]);

  /// Cancel every active run.
  void stopAll();

  /// Active (still-running) runs, newest first.
  List<WorkflowRun> get active;

  WorkflowRun? find(String id);
}
```

`RunWorkflow` is the runner seam — the same `PipelineRunner.run` signature the
old per-turn routing used, so the runner, the engine, and the parallel handler
are unchanged. `WorkflowRun` exposes `id`, `workflowName`, `goal`, `input`, a
`status` (`running` / `completed` / `failed` / `cancelled`), and the final
`outcome`.

## 5. What changed where

| Area | Change |
|---|---|
| `lib/pipeline/workflow_supervisor.dart` | **New.** The manager loop: `WorkflowSupervisor` + `WorkflowRun`. |
| `lib/session_controller.dart` | `_runTurn` no longer routes through the default workflow — normal turns run the plain agent. Added the `stopWorkflow` callback. |
| `lib/session_commands/command_context.dart` | Added `stopWorkflow` to the seam. |
| `lib/pipeline/pipeline_commands.dart` | `/workflow run` now launches in the background via the supervisor; new `/workflow stop [id]`. Hints updated (no longer "runs on every turn"). |
| `lib/tui_coordinator.dart` | Constructs one `WorkflowSupervisor`; wires `runWorkflow` (launch) and `stopWorkflow` (stop) to it. |
| `bin/tina.dart` | Headless prompts no longer auto-route through the default workflow; `--workflow <name>` still launches a workflow explicitly to completion. |
| `lib/pipeline/default_workflow.dart` | Helpers (`resolveDefaultWorkflowName`, `ensureDefaultWorkflowUsable`, `formatChatHistory`, `seedDefaultWorkflow`) and the seed kept; doc comments updated — they no longer drive per-turn routing. |

**Kept untouched:** the engine, the graph model, the parallel fan-out/fan-in
handlers, the codergen handler, the run store, the seeded `kDefaultWorkflowDotSource`
graph. The manager loop sits *above* all of them.

## 6. Why this shape

- **The chat is the right top-level context.** It holds the conversation history,
  the model, the permissions, and the user's attention. Wrapping every turn in a
  multi-node graph made a simple "hello" run a plan→review→execute pipeline. The
  manager loop restores the plain agent as the default and reserves the graph for
  work that wants it.
- **Background, not blocking.** A structured pipeline can take minutes. Launching
  it in the background lets the user keep talking — ask a question, switch
  session, queue a follow-up — while the run churns and reports back. This
  matches the attractor spec's direction that the orchestrator launches child
  work tool-mediatedly and does not hold job references (`docs/features/agent_pipeline.md`).
- **Reuse, don't rebuild.** Launch reuses `PipelineRunner.run`; monitoring reuses
  the engine's event stream; stopping reuses the engine's `cancelSignal`. No
  engine or handler changed.
- **The default graph is still the default graph.** It is just no longer
  mandatory. `/workflow run default` runs exactly the reviewed-plan-then-parallel
  pipeline the old routing ran — now on demand.

## 7. What is deliberately not in this change

- **A launch as an agent *tool*.** Today the main agent launches through the
  `/workflow run` slash command (the user drives it). An agent-callable
  `launch_workflow` tool (the model decides to run a workflow mid-turn, like the
  attractor spec's `conduct` tool) is the natural next step and is where the
  `launch({name, input, goal})` API is aimed.
- **Steering.** Stop is wired; mid-run steering (inject a message, change a
  node's prompt, re-route) is future work. The `house`/`manager_loop` shape
  anticipates it.
- **Multiple concurrent runs.** The supervisor supports more than one active run;
  the UI surfaces only the live event stream today. A runs-panel is future work.
