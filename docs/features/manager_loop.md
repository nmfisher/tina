# The manager loop — the main agent launches workflows as child runs

**Status:** Implemented (this branch)
**Date:** 2026-08-08

## 1. The change in one paragraph

The main agent **runs outside any workflow**. The chat conversation is the
persistent top-level context — it runs its own turns like any plain agent. A DOT
workflow is no longer wrapped around every chat turn. Instead, the main agent
**launches** a workflow itself, as a tool call, when it decides the work wants
one. The `launch_workflow` tool starts the graph as a **background run** and
returns immediately — node input/output streams into a **live run panel**
(§8) while it runs, and the **chat stays open** (the user can keep typing).
When the run finishes,
its completion **injects an agent turn** carrying the outcome, so the main agent
wakes and reports on it / acts on it. A running launch can be cancelled at any
time with the `stop_workflow` tool. The seeded `default.dot` stays as the
launchable default graph.

This is the **manager loop pattern**. In the attractor vocabulary a `house`-shaped
node maps to the `stack.manager_loop` handler type
(`packages/attractor/lib/src/graph.dart:219`): a supervisor that **observes,
steers, and waits** over a child pipeline. Here the supervisor is the main-agent
conversation; the child pipeline is a workflow run.

> Why "manager loop" and not a node? A house node would put the supervisor
> *inside* the graph. We do the opposite: the supervisor (the chat) sits
> *outside* the graph and treats the whole graph as one child it can launch. The
> shape→type mapping names the pattern; the main agent lives it.

## 2. Before and after

### Before (v0.1.3)

Every normal chat turn was routed through the DOT workflow while
`~/.tina/workflows/default.dot` existed (`resolveDefaultWorkflowName` in
`lib/pipeline/default_workflow.dart`). The "main agent" was a node *inside*
that graph. The turn blocked until the whole graph (`main → plan → review →
fan-out → exec → done`) finished.

Routing lived in `SessionController._runTurn`
(`lib/session_controller.dart`): it resolved the default workflow and called
the runner instead of the plain agent.

### After (this branch)

- **Normal turns run the plain agent.** `_runTurn` never consults a workflow.
  The chat is the top-level loop.
- **A workflow is a background child run, launched by the agent.** The main
  agent calls its `launch_workflow` tool with a task (and optionally a workflow
  name, defaulting to `default`). The call returns immediately with a run id;
  the run churns in the background under the `WorkflowSupervisor`
  (`lib/pipeline/workflow_supervisor.dart`) while the chat stays open.
- **Completion injects an agent turn.** When the run finishes, the supervisor's
  `onComplete` hook routes the outcome to the conversation controller
  (`SessionController.injectWorkflowResult`), which starts a synthetic turn the
  launching agent runs — it reports the result to the user and acts on anything
  the outcome leaves open.
- **The user does not type `/workflow run`.** There is no run/stop slash
  command; the agent launches with `launch_workflow` and cancels with
  `stop_workflow`. `/workflow list|show|new|edit` remain for inspecting/editing
  graphs. ESC cancels the *turn*, not the run — stopping a workflow is the
  agent's `stop_workflow` tool.
- **The seeded `default.dot` stays**, now as the launchable default graph the
  agent reaches for by default.

## 3. The launch path

The main agent's `launch_workflow` tool
(`lib/pipeline/launch_workflow_tool.dart`) is the execution path for workflows
from the chat. It hands the launch to a `WorkflowSupervisor` — constructed by
the coordinator (`lib/tui_coordinator.dart`) over a `RunWorkflow` seam backed
by `PipelineRunner.run`.

### 3.1 Launch (fire-and-forget)

The tool takes:

- **`input`** (required) — the task text. It flows into the run context as
  `context.input` and is expandable as `$input` in node prompts.
- **`workflow`** (optional, default `"default"`) — the DOT file to run, by name.

`execute` calls `supervisor.launch(name: …, conversationId: …, sink: …)` and
returns **immediately** with a "launched … (run N)" result — it does not await
the run. The launch sink is the launching conversation's host (it carries the
launch notice + the completion report), but the supervisor's `onLaunch` hook
swaps in a **live run panel host** as the run's stream sink
([WorkflowRun.sink]) before the runner starts — so the engine's progress
events and node text land in the panel, not the chat. Each node's block is
delimited by `▶ node` … `✔ node` (rendered by `PipelineRunner._renderEvent`)
with `✖ node: reason` on failure. No polling: events are pushed as they
happen.

### 3.2 Stop (the `stop_workflow` tool)

Cancelling **terminates the traversal**. The engine checks its `cancelSignal`
at the top of every step and before each retry delay
(`packages/attractor/lib/src/engine.dart`); once it has completed, the run
finishes immediately with `Outcome.fail('cancelled')` at the current node —
no `✖` cascade over the downstream nodes, and no post-cancel goal-gate loop.
Each supervised run owns a private cancel completer;
`supervisor.stop([runId])` completes it (no id → the most recent running
launch). The agent's `stop_workflow` tool is the user-facing cancel path —
the user asks the agent to cancel, or the agent decides itself (e.g. the run
is clearly off-track). The run aborts at its next node boundary and completes
with a `cancelled` outcome.

### 3.3 Completion → injected agent turn

The supervisor's completion path (`_classify` → `_reportBack` → `onComplete`):

1. The run's `status` is classified (completed / failed / cancelled).
2. A final `✔/✖` notice is posted to the launching chat.
3. The `onComplete` hook fires — the coordinator wires it to
   `SessionController.injectWorkflowResult`, which looks up the conversation
   that launched the run (by `conversationId`) and starts a **synthetic turn**
   through the normal turn path (`_startTurn`/`_runTurn`): echoed, persisted,
   and activity-managed like any turn. The prompt hands the agent the outcome —
   the run's **final output text** (the last node's response, e.g. the
   execution reviewer's summary) plus the run-store directory for the full
   transcript, or the failure reason — and instructs it to report to the user
   and act on anything left open.

If the conversation is already mid-turn when the run finishes, the outcome
prompt is **queued** (the same message queue a typed message uses) and drained
when the turn ends. Cancelled runs skip the injection — the cancellation was
already communicated through the stop path.

## 4. The `RunWorkflow` seam

```dart
typedef RunWorkflow = Future<PipelineRunResult> Function({
  required String workflowName,
  required AgentSink sink,
  String? input,
  String? history,
  Future<void>? cancelSignal,
  PipelineEventListener? onEvent,
});
```

`PipelineRunResult` carries the run's final `Outcome` (whose `text` holds the
last node's response) and the run-store directory the run wrote (manifest,
per-node prompt/response, checkpoints) — both land in the completion turn.

`RunWorkflow` lives in the app layer (`lib/pipeline/workflow_supervisor.dart`)
because it bridges two sibling packages — `Outcome` (attractor) and `AgentSink`
(tina_engine) — which do not depend on each other. In production the closure is
`buildRunner().run(...)` over a `PipelineRunner` constructed by the coordinator.
It is the same `PipelineRunner.run` signature the old per-turn routing used, so
the runner, the engine, and the parallel handler are unchanged.

## 5. What changed where

| Area | Change |
|---|---|
| `lib/pipeline/workflow_supervisor.dart` | **Restored + adapted.** `WorkflowSupervisor`/`WorkflowRun`/`RunWorkflow`. Fire-and-forget `launch` (now with `conversationId`); `stop`/`stopAll`; completion classification + report notice + `onComplete` hook. |
| `lib/pipeline/launch_workflow_tool.dart` | `LaunchWorkflowTool` rewritten non-blocking (launches via the supervisor, returns immediately) + new `StopWorkflowTool` (agent-callable cancel). |
| `lib/composition/agent_composition.dart` | `buildAgent` now takes a `WorkflowSupervisor` and wires both `launch_workflow` + `stop_workflow` into the shared tool set in both modes; `stop_workflow` allowed without prompting. |
| `packages/tina_engine/lib/src/agent/agent_pipeline.dart` | `_mainIdentity` rewritten: non-blocking launch — the run churns in the background, completion injects a follow-up turn; `stop_workflow` cancels; direct file tools for small changes; `delegate` for a single focused sub-task. |
| `lib/tui_coordinator.dart` | Builds the `WorkflowSupervisor` (over `buildRunner().run`) and wires both `buildAgent` call sites; `onComplete` → `controller.injectWorkflowResult` via a late `handleWorkflowComplete` field. |
| `lib/session_controller.dart` | New `injectWorkflowResult(WorkflowRun)` — finds the launching conversation and starts (or queues) a synthetic outcome turn; `_runTurn` still runs the plain agent. |
| `lib/pipeline/pipeline_commands.dart` | `/workflow run`+`stop` removed; `/workflow list\|show\|new\|edit` remain. Hints note workflows are launched by the agent. |
| `lib/pipeline/workflow_supervisor.dart` | Live tracking: `WorkflowRun.nodeStatus` + `onEvent`/`onFinished` hooks and the `onLaunch` constructor hook; `WorkflowRun.sink` — the run's stream sink, installed by the host in `onLaunch` (launch is reordered so the hook fires before the runner starts). |
| `lib/pipeline/pipeline_runner.dart` | `run()` gained an optional `onEvent` listener (the sink notices still fire) + `onNodeStart` — wired for TUI hosts only, it writes each node's dim header + full task into the panel transcript. |
| `packages/attractor/…/engine.dart`, `node_handler.dart`, `handlers/parallel_handler.dart` | The engine threads its progress listener into `NodeHandler.execute`; parallel branches emit `node_*` events (removing the documented limitation). |
| `packages/attractor/…/render/ascii_render.dart`, `run_status.dart` | `renderGraph` gained a `status` map → border glyphs per run state; new `NodeRunStatus` enum. |
| `lib/tui/run_panel_content.dart` | **New.** `RunPanelContent` — the live run transcript (wraps the run's chat region; dim `input disabled — read-only` label row). |
| `lib/tui/conversation_panel_coordinator.dart`, `packages/tina_console/…/conversation_panel.dart` | `bindExtra`/`unbindExtra` for non-conversation panels; `PanelFrame.onPanelKey` key hook. |
| `lib/tui_coordinator.dart` | `onLaunch` → `_openRunPanel`/`_closeRunPanel` (auto-open transcript panel: `_makeSpawnedHost` + `run.sink`, `s` stop / `x` close, PgUp/PgDn scrollback, comet, no focus steal). |
| `bin/tina.dart` | Seed message corrected; `--workflow <name>` still launches a workflow explicitly to completion (a separate scripting mode). Node writes prompt per write interactively; headless they auto-deny — pass `--yolo` or `--allow write`/`--allow edit` to let a headless workflow change files. |
| `lib/pipeline/workflow_permission_asker.dart` | **New.** `WorkflowPermissionAsker` — renders a node agent's write/edit permission prompt (tool + preview) into the run panel and reads `y/n/a/d`. Serialized with human gates through the attention queue. |
| `lib/tui/attention_queue.dart` | **New.** `AttentionQueue` — one serialized FIFO per TUI for modals (gates, loop-budget confirms, permission asks), so concurrent dialogs never race on `editor.readKey()`; a queued modal posts a dim "waiting for your input" notice to its run's sink. |
| `packages/attractor/…/engine.dart` | Loop bounds: per-node visit cap (`max_node_visits`, default 8), whole-run step cap (`max_steps`, default 200), and per-gate retry budgets (`max_retries`) — exceeded budgets consult `onLoopBudgetExceeded`; interactive runs pause with a human gate (continue resets the budget / abort), headless fails with a clear reason. Transient backend errors fire `Outcome.retry` so `max_retries` finally runs; a failed node with no unconditional outgoing edge dead-ends the run instead of falling back to any edge. |
| `lib/tui/run_panel_content.dart` | Label row now reads `s stop · x close · read-only workflow view` (the keys were always wired; the label now documents them). |

**Kept untouched:** the graph model, the codergen handler, the run store, the
seeded `kDefaultWorkflowDotSource` graph. The supervisor, tools, and run panel
sit *above* the engine.

## 6. Why this shape

- **The chat is the right top-level context.** It holds the conversation history,
  the model, the permissions, and the user's attention. Wrapping every turn in a
  multi-node graph made a simple "hello" run a plan→review→execute pipeline. The
  manager loop restores the plain agent as the default and reserves the graph for
  work that wants it.
- **The conversation must not block.** A workflow is a multi-minute child run; a
  blocking launch would tie the chat to the run and serialize the conversation.
  Launching fire-and-forget keeps the chat open, and the injected completion
  turn makes the outcome land back in the conversation — the agent reports and
  acts on it without the user having to nudge.
- **The agent decides.** The prompt steers the main agent to launch a workflow
  for substantial work and use the file tools for small changes — so launching
  is the agent's own decision, not the user's. Launch and cancel are both honest
  entries in its action space (`launch_workflow` + `stop_workflow`).
- **Reuse, don't rebuild.** Launch reuses `PipelineRunner.run`; monitoring reuses
  the engine's event stream; stopping reuses the engine's `cancelSignal` (now
  owned per-run by the supervisor); the completion turn reuses the controller's
  existing `_startTurn`/`messageQueue` machinery. The launch path itself
  changed no engine or handler.
- **The default graph is still the default graph.** It is just no longer
  mandatory or user-driven. `launch_workflow` runs exactly the
  reviewed-plan-then-parallel pipeline the old routing ran — now on demand, by
  the agent.

## 7. What is deliberately not in this change

- **Steering.** Stop is wired (the `stop_workflow` tool + the run panel's `s`
  key); mid-run steering (inject a message, change a node's prompt, re-route)
  is future work. The `house`/`manager_loop` shape anticipates it.
- **Persisted run panels.** A run panel is a session-lifetime view; closing it
  (the `x` key) only closes the view, not the run. There is no runs history
  panel across sessions.
- **Headless `--workflow`.** The `--workflow <name>` CLI flag still calls
  `PipelineRunner.run` directly to completion — a separate scripting entry point,
  not the agent path.

## 8. The live run panel

When a workflow launches, a **read-only transcript panel auto-opens in the
right column** (like a spawned agent panel) showing the run as it happens — a
chat-style conversation of the run:

- **The run streams into the panel, not the chat.** The supervisor's
  `onLaunch` hook builds a spawned-style host (a detached chat region, via the
  same `_makeSpawnedHost` machinery spawned agent panels use) and installs it
  as the run's stream sink ([WorkflowRun.sink]) **before the runner starts**,
  so every node's text, tool calls, and progress render in the panel. The main
  chat sees only the launch notice and the completion report (plus the
  follow-up turn the completion injects).
- **Per-node blocks.** Each node opens with `▶ <node>` (the engine's
  `node_started` notice), a dim `──── node: <id> ────` header, and the node's
  **full task as received** — its declared context (the prior outputs it named
  in `context="…"`, nothing more) plus its own prompt — in user style; then
  the live streamed output + tool calls;
  `✔ <node>` closes it. The header + input block are written by the runner's
  `onNodeStart` hook, wired **only for TUI hosts** (headless `--workflow` keeps
  the bare `▶` notices). Retries re-show the block after the `↻` line, and
  **parallel branches stream interleaved** with their own blocks (the fan-out
  runs each branch through the same backend).
- **Input is disabled.** The panel never binds the shared editor; its bottom
  row carries a dim `s stop · x close · read-only workflow view` label. Typing
  always lands in the chat.
- **Keys while focused**: `s` stops the run (same as the `stop_workflow`
  tool), `x` closes the panel (the run continues unless stopped — the rest of
  the run buffers into the detached region and is discarded), PgUp/PgDn scroll
  the transcript (the frame badge shows lines that arrived while scrolled up).
- **Node writes prompt per write.** A node agent's `write`/`edit` call is NOT
  auto-allowed: the prompt (tool + diff preview, `y/n/a/d` — `a` remembers
  "always" for the rest of the run) renders into the run's panel and reads
  from there, exactly like the main agent's prompts. `bash` stays gated by the
  user's own policy (`--yolo` / `--allow bash:…` re-enables it). Headless runs
  (no one to prompt) auto-deny writes — run with `--yolo` or
  `--allow write`/`--allow edit` to let a headless workflow change files.
- **One modal at a time.** Gates (clarify), loop-budget confirms, and write
  prompts all go through a single attention queue: while one dialog is open the
  next waits and its run panel shows a dim "waiting for your input" notice.
- **Lifecycle** — the frame's comet sweeps while the run is in flight and
  settles on completion; the transcript ends with the engine's
  `✔/✖ workflow complete/failed` line. The panel stays open showing the final
  state until closed. Multiple concurrent runs stack one panel each.

The panel is wired in the coordinator: the supervisor's `onLaunch` hook opens
it synchronously ([RunPanelContent](`lib/tui/run_panel_content.dart`), a
read-only `PanelContent` wrapping the run's chat region), `run.sink` is set to
the panel host before the run starts, and `onFinished` settles the busy cue.
