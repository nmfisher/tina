# Agent Pipeline — a main agent that orchestrates live sub-agents

## Status (updated 2026-07-03)

> The **v1 slice** (leaf sub-agents + the await-driven `delegate` tool, with
> per-agent provider/model selection via config), the **pipeline phase** (composite specs
> run as ordered stage chains), and the **background-tools phase**
> (`dispatch`/`collect`/`continue`/`cancel`) have shipped. Workflows and the
> config-driven catalog remain pending. Several parts of the design below were
> **superseded** by the implementation — the corrections are listed here and the
> code (`lib/agent/`, `lib/tools/delegate_tool.dart`,
> `lib/tools/delegation_base.dart`, `lib/tools/background_tools.dart`,
> `lib/tui_coordinator.dart`) is the source of truth. A phase-4 hygiene pass
> (a shared delegation base + `AgentToolContext`, a result-extraction fix, and a
> `collect` continuable marker) is documented under "Completed (phase 4)" below.
> Plan: `plans/inherited-purring-bengio.md`.

### ✅ Completed (v1 — leaf sub-agents + `delegate`)

- **`AgentSpec` + `AgentCatalog`** (`lib/agent/agent_spec.dart`, `c6bc813`) —
  leaf-only, carrying a `"provider/model"` **`reference`** (see correction 1).
- **`JobAgentEvent`** wrapper + **`SubAgentSink`** (`c6bc813`) — non-invasive
  job-tagged events on a per-job bus; no main-chat writes.
- **`SubAgentScheduler` + `SubAgentJob` + `DelegationResult`**
  (`lib/agent/sub_agent_scheduler.dart`, `9119620`) — detached leaf `spawn`,
  fail-closed policy, auto-deny asker, `maxConcurrent` semaphore, per-job
  cancel, `cancelAll()`/`dispose()`, merged events stream, result extraction +
  truncation (16 000 char cap, empty → error).
- **`DelegateTool` + `withDelegateTool`** (`lib/tools/delegate_tool.dart`,
  `0020ab0`) — await-driven fan-out/merge, `agent`-name enum in the schema,
  main-turn cancel propagates to spawned jobs.
- **Wiring** (`lib/tui_coordinator.dart`, `3e28b9e`) — code-built catalog
  (one `research` spec), session-scoped scheduler, `delegate` injected into the
  main agent, minimal `«label: → tool»` progress, teardown. Nesting guarded by
  `maxDepth` + a `delegateToolBuilder` hook.

### ✅ Completed (phase 2 — pipelines / composite agents)

- **Composite `AgentSpec` + `PipelineStage`** (`lib/agent/agent_spec.dart`,
  `055590f`) — `pipeline`/`role`/`isComposite` fields; `AgentCatalog.byRole`
  (falls back to the spec's name) resolves stage roles.
- **`_runPipeline` in `SubAgentScheduler`** (`lib/agent/sub_agent_scheduler.dart`,
  `07ff240`) — `_run` branches on `isComposite`; a composite runs its stages in
  order, handing each stage's output forward as `--- prior work ---` context,
  short-circuiting on a `haltOnFail` stage error, the final stage's output as
  the result. Stage transitions surface as `«label: → role»` notices. See
  corrections 7 (deadlock fix) and 8 (maxDepth backstop).
- **`qa` catalog seed + notice rendering** (`lib/tui_coordinator.dart`,
  `07ff240`) — a `qa` pipeline (implement → verify → test) and its role agents;
  the progress listener now also renders `NoticeAgentEvent`s, so stage
  transitions are visible. Composites delegate like any agent — no
  `DelegateTool` change.

### ✅ Completed (phase 3 — background tools)

- **Scheduler primitives** (`lib/agent/sub_agent_scheduler.dart`, `d77352b`) —
  leaf jobs now retain their conversation `history` (so a `continue` can build
  on them) and every terminal job exposes its `resolvedResult`; `spawn` takes an
  optional `seedHistory`; `SubAgentJobStatus.isTerminal`; `jobById(id,
  {conversation})` for scoped lookups. No behavior change for existing callers.
- **The four tools** (`lib/tools/background_tools.dart`, `31e98a5`) —
  `dispatch` (detach; returns job handles, survives the turn), `collect`
  (pull completed results + pending status, by id or for the whole
  conversation; per-entry content cap), `continue` (resume a finished leaf job
  by seeding a new job from its history + a follow-up; rejects running/composite
  jobs), `cancel` (stop a job by id, awaiting briefly). `withBackgroundTools`
  appends all four. Jobs are addressed by id and scoped to the originating
  conversation; result delivery stays pull-based.
- **Wiring** (`lib/tui_coordinator.dart`, phase 3) — the main agent gets the
  four tools alongside `delegate`, all allow-by-default (the orchestrator
  managing its own spawned work). Nested sub-agents stay `delegate`-only for now
  (see deferred items).

### ✅ Completed (phase 4 — hygiene: refactor + result-extraction fix)

A pre-Part-II cleanup of the agent layer, in three commits:

- **`_extractResult` correctness fix** (`lib/agent/sub_agent_scheduler.dart`,
  `3358e94`) — a leaf that hit its step ceiling or was cancelled mid-loop ended
  on a tool-result turn, so the old reverse-scan returned an *earlier*
  mid-reasoning preamble as the final answer (silently wrong, status `done`).
  Now only the *last* message counts, and only if it's an assistant text turn;
  any other terminal shape reports an honest non-finish error. The
  "Result extraction" section below described the intended behavior all along —
  the implementation now matches it.
- **Shared delegation base + `AgentToolContext`** (`lib/tools/delegation_base.dart`,
  `73bee61`) — `delegate` and `dispatch` were ~90% duplicated (same schema,
  parsing, spawn block). They now extend `DelegationToolBase`, which owns the
  shared parts; each implements only its post-spawn behavior (await+merge vs
  return handles). The configuration every spawning tool needs — `scheduler`,
  `catalog`, `parentReference`, `parentPolicy`, `originConversationId`,
  `depth` — is bundled in `AgentToolContext` (`sub_agent_scheduler.dart`) and
  threaded through once, so the wiring, `withDelegateTool`/`withBackgroundTools`,
  and the nesting builder no longer repeat it (and risk drifting).
  `NestedDelegateToolBuilder` now takes an `AgentToolContext`; the builder
  collapsed to `(ctx) => DelegateTool(ctx)`. Behavior identical; net −114 lines.
- **`collect` continuable marker** (`lib/tools/background_tools.dart`,
  `4df9a21`) — finished leaves are flagged `(continuable)` in `collect` output,
  so the orchestrator can tell a leaf it can `continue` from a composite it
  can't, without trial and error.

### ⏳ Pending (deferred)

- **Nestable background tools** — `dispatch`/`collect`/`continue`/`cancel` are
  wired into the main agent only; a `BackgroundToolBuilder` (akin to
  `delegateToolBuilder`) would let sub-agents manage their own background jobs.
  The scheduler is session-global, so this is wiring work, not new mechanism.
- **Part II — adaptive workflows** — the `conduct` tool, `WorkflowRun`,
  query-adaptive DAGs.
- **Config-driven catalog / `/agents` command** — the catalog is code-built;
  end users can't add or re-pin agent specs at runtime.
- **Per-agent UI** — only the one-line `«label: …»` progress ships (tool starts
  and stage-transition notices); rich per-agent views are the (separate)
  tool-strip work.
- **Push / auto-injected results**, **token-budget roll-up** across jobs,
  **persistence of sub-agent turns** (delegated answers survive only as
  `ToolResultBlock`s in the main conversation), **Isolates / crash-isolation**.
- **Non-interactive (`--prompt`) delegation** — delegation is wired only in the
  interactive `TuiCoordinator` path (see correction 6).
- **Structured verdict objects** for `haltOnFail` stages (a stage returns a plain
  error result today), **parallel-within-pipeline stages** (stages are strictly
  sequential; parallel fan-out remains `delegate`), **pipeline graph cycle
  analysis** (only the `maxDepth` backstop ships).

### ⚠ Known sharp edges (documented; not yet fixed)

- **Concurrency: background jobs can starve an interactive `delegate`
  (priority inversion).** One session-global `maxConcurrent` semaphore caps all
  live leaves, FIFO, with no distinction between spawns the orchestrator is
  *awaiting* (`delegate`) and fire-and-forget ones (`dispatch`). If background
  jobs saturate the pool, a subsequent `delegate` parks in the queue until one
  finishes — the turn the user is blocked on waits behind work they aren't
  watching. This is latency, not correctness, and only bites under saturation.
  Holding is non-preemptive (a running LLM call can't be paused), so reordering
  the queue alone wouldn't help — the fix is to reserve interactive headroom
  (cap background concurrency below `maxConcurrent`, or split the pool). See
  [Concurrency cap](#concurrency-cap). Deferred until Part II: the fix needs
  `spawn` to know whether it's serving an interactive or background caller,
  which richer orchestration will want anyway.
- **Unbounded job retention.** `_jobs` is never trimmed, and finished leaves
  retain their full grown `history` (so `continue` can reseed). A long session
  dispatching many background jobs grows memory monotonically; there is no
  sub-agent compaction (the main agent has `compact`; sub-agents don't). Not a
  problem in practice yet; reaping terminal-and-collected jobs is the natural
  follow-on.

### ❌ Plan corrections (where the design below was wrong / superseded)

1. **`AgentSpec.model` → `reference` (the load-bearing one).** The sketch below
   has a `model` field and the scheduler's
   `buildProvider: (model) => registry.build(config.provider, model, …)`
   varies **only the model** — every sub-agent shared the main session's
   provider + key. That predates the provider registry
   (`registry.build("provider/model")`, which resolves a provider **and** its
   key from env per provider). Shipped: `AgentSpec.reference` is a
   `"provider/model"` string; the scheduler calls
   `registry.build(spec.reference ?? parentReference)`, so a spec can run a
   *different provider* with its own env-resolved key. This splits the doc's
   "account context" into **per-provider credentials** (registry-resolved) vs
   **inherited fail-closed policy**.
2. **No `pipeline` / `role` / `isComposite` in v1.** Those fields (and
   `PipelineStage`) were absent from the v1 `AgentSpec` (leaf-only). They shipped
   in phase 2 — see the "Completed (phase 2)" section above.
3. **Scheduler ownership.** The doc (Files table + Wiring) says
   `SessionManager` owns/disposes the scheduler. Shipped: **`TuiCoordinator`
   owns and disposes it** (in `_restoreTerminal`), because `closeAll` is
   synchronous and `scheduler.dispose` is async. `SessionManager` is unchanged.
4. **`_toolsFor` / `DelegateTool` coupling.** The doc's `_toolsFor` lives in the
   scheduler and constructs `DelegateTool(this, depth: depth+1)` directly — a
   scheduler→tool import coupling. Shipped: the scheduler has a nullable
   `delegateToolBuilder` typedef (set by the wiring) so it doesn't import
   `delegate_tool.dart`, keeping the tiers independently compilable.
5. **Event tagging.** The `SubAgentSink` sketch mutates a `tag` onto each event
   (`TextAgentEvent(s)..tag = jobId`). Shipped: a non-invasive
   `JobAgentEvent(jobId, label, event)` wrapper — the doc's own alternative.
6. **Non-interactive path.** The doc claims "the non-interactive `--prompt`
   path wires the same way." Not yet — see Pending.
7. **Composite jobs don't hold a concurrency slot (deadlock fix).** The
   `_runDetached` sketch acquires the semaphore unconditionally, then
   `_runPipeline` calls `spawn` (which acquires again per stage). Under
   `maxConcurrent` concurrent pipelines, every orchestrator would hold a slot
   while awaiting a stage slot that could never free → deadlock. Shipped: only
   leaf jobs acquire the semaphore; composites are pure coordination (no
   provider/agent loop/tools), so they consume none of the resource it caps. A
   test (3 concurrent 2-stage pipelines under `maxConcurrent: 2`) would hang
   without this fix.
8. **Nesting backstop is `maxDepth`, not cycle analysis.** The doc says "a
   pipeline must not list itself as a stage" but enforces nothing. Shipped: a
   composite at `depth >= maxDepth` errors instead of recursing. There is no
   graph cycle analysis in v1 (real catalogs won't cycle); `maxDepth` is the
   only backstop.

---

## Default DOT workflow routing (2026-08-06)

Since v0.1.3-ish, **every normal chat turn routes through an editable DOT
workflow by default** — a planner → reviewer → executor pipeline — instead of
the plain main-agent loop, while `~/.tina/workflows/default.dot` exists.

- **Seed**: first launch (and `--init-config`) writes `default.dot`
  (`lib/pipeline/default_workflow.dart`, `kDefaultWorkflowDotSource`): a
  `start(Mdiamond) → plan(orchestrator) → review(verifier) ⇄ plan → execute
  (orchestrator) → done(Msquare)` graph with `VERDICT:` routing (`submit` /
  `approve` / `revise` back-edge).
- **Routing rule** (`resolveDefaultWorkflowName`): the turn runs through the
  workflow when `default.dot` exists — unless `[default] workflow = "none"`
  in `~/.tina/config` disables routing, or the config names a different
  workflow (`[default] workflow = "foo"` → `foo.dot`).
- **Fallbacks**: a missing, unparseable, or invalid `default.dot` shows a
  warning and falls back to the plain agent (chat never bricks); an
  explicitly-configured workflow that's missing on disk warns + falls back;
  a workflow that fails at runtime ends the turn like any failed turn.
- **Prompt expansion**: node prompts can reference `$input` (the user's
  message), `$history` (the truncated chat transcript, 60k chars, newest
  kept), and `$goal` (the graph goal) — expanded by `expandTemplate`
  (`packages/attractor/lib/src/handlers/codergen_handler.dart`). `history`
  is an engine-managed context key, so it only surfaces where a prompt
  explicitly asks for it.
- **"One or more executors"** comes from the `execute` node's role:
  `orchestrator` (canDelegate) splits the work and delegates to 1..N
  `implementer` sub-agents via the existing `delegate` tool — no engine-level
  parallel/fan-in (still deferred).
- **Edit / disable**: `/workflow edit default` opens the visual node editor;
  delete `default.dot` or set `[default] workflow = "none"` to go back to the
  plain single-agent path.
- **Known limitation**: a pipeline turn streams its output into the chat but
  does not append to session history, so `$history` on later turns only
  accumulates user messages until the runner surfaces the final node text.

---

## Context

Today every chat turn runs through one `Agent` (`lib/agent/agent.dart`) — a tool-calling
loop with one provider (one model), one `PermissionPolicy`, one tool set, and one output
sink. The only multi-agent seam is **horizontal**: `Session` holds many `Conversation`s the
user switches between manually (`session.dart`, `session_manager.dart`).

This doc specs the **vertical/hierarchical** axis: a **main agent orchestrates/delegates to
live sub-agents**, where each agent may use a **different model** and carry **different
permissions**. A sub-agent is just an `Agent` constructed differently — different provider,
policy, tools, system prompt, and sink — running the *same* tool-calling loop.

Crucially, **sub-agents are not confined to a single turn.** They churn through tasks
independently and in parallel, often outliving the turn that launched them. So delegation is
**not** a nested RPC call the orchestrator blocks on — it's **detached, long-lived async
work** managed by a scheduler. This is unblocked by the `AgentSink` decoupling
([`tool_strip/stage_04_agent_observer.md`](tool_strip/stage_04_agent_observer.md)): because
all agent output flows through a sink (and an event bus), a sub-agent can emit to its own
labeled event stream instead of the main chat. **Land the decoupling (Stage 4 + R2) before
this.** Per-agent UI views are out of scope here — this doc is about the agent/session
abstraction and the async runtime.

### Decisions (defaults; re-confirmable)
- **Async model — detached jobs on the single isolate.** A session-scoped
  `SubAgentScheduler` owns long-lived `SubAgentJob`s that run as detached `Future`s on
  Dart's event loop. "In parallel" = event-loop interleaving during `await`s, not OS threads.
  No `Isolate`s in v1 (the agent loop is I/O-bound; revisit only for crash-isolation).
- **`spawn` is the universal primitive; tools choose the mode.** `delegate` (await, the
  default), `dispatch` (detach/background), `collect` (gather results later).
- **Main→sub communication is tool-mediated only.** The orchestrator holds no direct
  reference to the scheduler or to jobs — launching, querying, continuing, and cancelling
  sub-agents are all tool calls, so the agent loop, permission gate, and result flow stay
  identical to any other tool. Sub-agent → orchestrator is tool *results*; the orchestrator
  never receives push and never subscribes to the event bus (that's UI telemetry).
- **The main agent is a proactive spawner.** The spawn tools are native to it by default, so
  in any turn it can decide on its own initiative to spin up sub-agents — including
  `dispatch`ing background agents that churn across later turns. The user need not request
  delegation. It is still turn-driven in v1 (no idle loop, no event wake-ups); those layer on
  the same scheduler later.
- **Ordered routing = pipelines as composite agents.** A pipeline (e.g. implement → verify →
  test) is itself an entry in the `AgentCatalog`; the main agent delegates to it like any
  agent (`delegate` to await, `dispatch` to detach) and it internally runs its stages in
  order. No new invocation mechanism — pipelines reuse delegation, the scheduler, and
  tool-mediated communication. Stages designate agents by **role** (verifier, tester).
- **Result delivery — await-driven for v1.** The orchestrator explicitly awaits or collects;
  background results are pulled, never auto-injected mid-turn. Push/injection is a later
  option (racy).
- **Sub-agent permissions — fail-closed.** A sub-agent inherits the parent policy but any
  `ask` resolves to `deny`. Sub-agents never prompt the user and can't escalate. A spec may
  still *grant* more via its own static rules.
- **Result — verbatim final text + size cap.** Return the sub-agent's final assistant text,
  truncated so a research agent can't flood the orchestrator's context. No extra
  summarization call.

> **Follow-on (Part II):** the pipelines above are *static*, fixed DAGs declared in the
> catalog. [Part II](#part-ii--adaptive-workflows-the-conductor--fugu-ultra-variant) generalizes
> them to **query-adaptive workflows** the orchestrator emits at run time (the Sakana Fugu /
> Conductor architecture) — same scheduler, same tool-mediated channel, richer topologies.

## The async model

### Single-isolate event-loop concurrency, not Isolates

The agent loop is almost always `await`ing an HTTP response from the provider or a subprocess
(`bash`). On Dart's single isolate that already yields real concurrency — many provider
streams in flight at once — because `await` returns control to the event loop and every
other agent advances in the gap. **"In parallel" means interleaved on the event loop, not
threaded.**

`Isolate`s (true OS parallelism) are intentionally **not** used in v1: they have separate
heaps and serialize everything by message, and sub-agents share live state (`Screen`, the
event bus, the tool registry) that doesn't cross isolate boundaries cheaply. Revisit Isolates
only for **crash-isolation** (a runaway sub-agent in its own isolate could be hard-killed
without taking down the main loop) or if we add CPU-bound tools — neither is the bottleneck
today (all current tools are async I/O or subprocesses).

### This is already how the app works horizontally

`SessionManager` runs background `Conversation`s concurrently today: while your active turn
`await`s `agent.run()`, the event loop advances other conversations' turns. Sub-agent jobs
are the **vertical** analogue — a new *owner* of the same shape (`Completer<void>` cancel
signals, detached output), not a new concurrency primitive. The infrastructure for
"many agents running at once while the user's active turn awaits" already exists.

## Overview

```
                ┌─────────────────────────────────────────┐
   user ──────▶ │  main agent (orchestrator)              │
   (turn N)     │  model A · policy P · tools + delegate  │
                └─────────┬───────────────────────────────┘
                          │ spawn (detached; not awaited inline)
                          ▼
            ┌──────────────────────────┐  session-scoped, survives turns
            │  SubAgentScheduler       │  ◀── maxConcurrent semaphore
            │  jobs: {j1, j2, j3, ...} │
            └───┬─────────┬─────────┬──┘
                ▼         ▼         ▼            each job: own provider/model,
            ┌─────┐   ┌─────┐   ┌─────┐          fail-closed policy, tool subset,
            │ j1  │   │ j2  │   │ j3  │          SubAgentSink → labeled events
            │research│ │research│ │…│
            └──┬──┘   └──┬──┘   └──┬──┘
               │ AgentEvent bus (tagged job id / label) ──▶ UI renders
               │                                    «label: → …»
               ▼ Future<DelegationResult>
             (completes when the loop ends — awaited now, or collected later,
              this turn or a future one)
```

## The main agent spawns proactively

The main agent is itself an **autonomous spawner**, not a relay that delegates only when the
user asks. The spawn tools (`delegate`, and `dispatch` for background) are **native to it by
default** — wired unconditionally via the `AgentBuilder` whenever the catalog is non-empty —
so in any turn the model can decide on its own initiative to spin up sub-agents, including
firing off `dispatch`ed agents that churn in the background across later turns. The user might
say "fix the bug" and the main agent, on its own, dispatches a research agent to locate it
while it keeps working.

This stays within the turn-driven loop in v1: the main agent does **not** run an idle loop or
wake on events between user turns. Both are natural later additions and would layer on the
same scheduler — an autonomous tick or an event bridge would simply invoke the main agent's
turn with no user input. "On its own" here means the agent's own tool-call decision, which is
exactly how main→sub communication works (tool-mediated only).

## Core abstractions

All UI-free, in `lib/agent/`.

### `AgentSpec` + `AgentCatalog` — `lib/agent/agent_spec.dart`

> **⚠ Superseded by v1** (see Status): the shipped `AgentSpec` is **leaf-only**
> and carries a `"provider/model"` **`reference`** — not the `model`, `pipeline`,
> `role`, or `isComposite` fields sketched below. Those belong to the pending
> pipeline phase. The sketch is retained for that future work.

Static description of an agent type. Immutable config, no behavior.

```dart
/// One stage of a composite (pipeline) agent. [role] designates the leaf agent
/// that runs this stage (resolved via `AgentCatalog.byRole`).
class PipelineStage {
  final String role;            // 'verifier' — which designated agent runs this stage
  final String task;            // stage-specific framing; the runner appends prior outputs
  final bool haltOnFail;        // an error result here short-circuits the chain
  const PipelineStage({required this.role, required this.task, this.haltOnFail = false});
}

class AgentSpec {
  final String name;                 // 'research', or 'qa' for a composite pipeline
  final String description;          // shown to the orchestrator in the delegate tool docs
  final String? role;                // 'verifier' — how pipeline stages designate this agent
  // Leaf agents only (ignored when [pipeline] is set):
  final String? model;               // null = inherit the active conversation's model
  final Set<String>? toolNames;      // null = all base tools; else subset by schema name
  final PermissionPolicy? policy;    // null = derive fail-closed from the parent
  final String? systemPrompt;        // null = buildSystemPrompt()
  final int? maxSteps;               // null = sub-agent default (e.g. 25)
  // Composite (pipeline) agents only:
  final List<PipelineStage>? pipeline;   // if set, this agent runs an ordered chain, not an LLM loop
  const AgentSpec({...});
  bool get isComposite => pipeline != null;
}

class AgentCatalog {
  AgentCatalog(Iterable<AgentSpec> specs);
  AgentSpec? operator [](String name);      // by name
  AgentSpec? byRole(String role);           // by role (v1: one spec per role)
  List<AgentSpec> get all;                  // enumerates agents for the delegate tool description
}
```

### `SubAgentJob` + `SubAgentScheduler` — `lib/agent/sub_agent_scheduler.dart`

> **⚠ Superseded by v1** (see Status): the shipped scheduler builds each
> sub-agent's provider via **`registry.build(spec.reference ?? parentReference)`**
> — *not* the `buildProvider: (model) => providerFactory(config.provider, …)`
> closure sketched below (which varied only the model). It also owns nesting via
> a `delegateToolBuilder` hook rather than a direct `DelegateTool` reference, and
> the **`TuiCoordinator`** (not `SessionManager`) owns/disposes it.

A `SubAgentJob` is a handle to running (or completed) work. Cheap to create; owned by the
scheduler, not the turn. The `Future` completes when the loop ends; the `Stream` carries
live progress tagged with this job's id/label.

```dart
enum SubAgentJobStatus { queued, running, done, errored, cancelled }

class DelegationResult {
  final String content;
  final bool isError;
  const DelegationResult(this.content, {this.isError = false});
  factory DelegationResult.error(String m) => DelegationResult(m, isError: true);
}

class SubAgentJob {
  final String id;
  final String label;                // spec.name, for «label: …» rendering
  final AgentSpec spec;
  final String originConversationId; // who spawned it
  SubAgentJobStatus status;
  Future<DelegationResult> get result;   // completes once (ok / errored / cancelled)
  Stream<AgentEvent> get events;         // tagged with this job's id/label
  Future<void> cancel();                 // signals this job only
}

class SubAgentScheduler {
  final LlmProvider Function(String model) buildProvider; // wraps the existing providerFactory
  final ToolRegistry baseTools;          // pure base tools, NO delegate tool
  final AgentCatalog catalog;
  final int maxConcurrent;               // semaphore — don't hammer the provider (e.g. 6)
  final int defaultMaxSteps;             // e.g. 25
  final int resultCharCap;               // e.g. 16000

  /// The universal primitive. Kicks off agent.run() as a detached Future and
  /// returns immediately; the job churns independently of the calling turn.
  SubAgentJob spawn({
    required AgentSpec spec,
    required String task,
    required PermissionPolicy parentPolicy,
    required String parentModel,
    required String originConversationId,
    Future<void>? sessionCancelSignal,   // session/app scope (cancels all on shutdown)
  });

  List<SubAgentJob> get jobs;            // all jobs, for UI / status / collect
  List<SubAgentJob> jobsFor(String conversationId);
  Future<void> cancelAll();              // session teardown
  Future<void> dispose();
}
```

Internals:
- `spawn` acquires the concurrency semaphore (queueing if `maxConcurrent` are live), builds
  the provider (`spec.model ?? parentModel`), the filtered tools (`_toolsFor`), the fail-closed
  policy, a per-job `AgentEventBus`, and a `SubAgentSink` that emits onto it. It runs
  `agent.run(...)` as a detached Future whose completion writes the `DelegationResult` into a
  `Completer` (the job's `result`) and flips `status`. It is **not** awaited by `spawn`.
  Composite specs (`pipeline != null`) take a different branch — see
  [Pipelines as composite agents](#pipelines-as-composite-agents-ordered-routing).
- A per-job `Completer<void>` is the cancel signal; `job.cancel()` completes it (and the
  agent loop exits like today's ESC). The session/app scope fans into every job for
  `cancelAll()`.

### `SubAgentSink` — `lib/agent/agent_sink.dart` (from Stage 4, adapted)

The adapter that turns the sub-agent's `AgentSink` calls into **labeled events on the job's
bus**. It does not write the main chat directly — rendering is a bus subscriber (UI concern),
which keeps a single progress channel for both await-driven and detached jobs:

```dart
class SubAgentSink implements AgentSink {
  final String label;            // spec.name
  final String jobId;
  final AgentEventBus bus;
  SubAgentSink({required this.label, required this.jobId, required this.bus});

  void text(String s)            => bus.emit(TextAgentEvent(s)..tag = jobId);   // see note
  void toolStart(ToolStartEvent e)   => bus.emit(ToolAgentEvent(e));
  void toolOutput(ToolOutputEvent e) => bus.emit(ToolAgentEvent(e));
  void toolComplete(ToolCompleteEvent e) => bus.emit(ToolAgentEvent(e));
  void notice(String m, {NoticeKind kind = NoticeKind.info}) => bus.emit(NoticeAgentEvent(m, kind));
  void newline() => {};
  void activityStart() => {};
  void activityStop()  => {};
}
```

> The `R5` bus carries `AgentEvent`s; each is tagged with the job's id/label (add a `tag`
> field to `AgentEvent`, or wrap events in a `JobAgentEvent(jobId, label, AgentEvent)`). The
> TUI subscribes to the scheduler's merged stream and renders one compact `«{label}: → …»`
> line per `toolStart` and a completion line per job — for the **active** conversation only.

## The communication surface — tool-mediated, addressable by job id

The orchestrator has **no direct reference** to the scheduler or to `SubAgentJob`s. Every
interaction is a tool call — this *is* the whole main→sub channel, and it keeps the agent
loop, the permission gate, and the result flow identical to any other tool. Directionality:

- **Orchestrator → sub-agent:** tool *calls* (`delegate`, `dispatch`, `continue`, `cancel`).
- **Sub-agent → orchestrator:** tool *results* (`delegate`'s return, `collect`'s output). The
  orchestrator learns about a job only by calling a tool and reading the result — never by
  push, never by subscribing to a stream.
- **Sub-agent → user/UI:** the `AgentEventBus` (live `«label: → …»` rendering). This is UI
  telemetry, **not** orchestrator communication.

Sub-agents are **addressable by job id** (returned by `dispatch`/`delegate`), which is what
makes `collect` / `continue` / `cancel` possible. `spawn` is the primitive underneath; the
tools choose the mode:

| Tool | Mode | Ship | Purpose |
|---|---|---|---|
| `delegate` | await | v1 | spawn + await; merged result as a `ToolResult` |
| `dispatch` | detach | phase 3 | spawn without awaiting; return job handles |
| `collect` | pull | phase 3 | read completed results (+ pending status) by job id |
| `continue` | resume | phase 3 | send a follow-up message to a prior job's conversation |
| `cancel` | signal | phase 3 | cancel a job by id |

All five have shipped (`delegate` in v1; the rest in phase 3). The scheduler
supported detached jobs from day one — only the tools were phased.

### `delegate` — await-driven (default)

> **✅ Phase 4 refactor:** `delegate` and `dispatch` extend
> `DelegationToolBase` (`lib/tools/delegation_base.dart`), which owns the shared
> `delegations` schema, the resolver, and `spawnAll`; the two tools differ only
> in post-spawn behavior (await+merge vs return handles). The
> scheduler/catalog/reference/policy/conversation/depth a spawning tool runs
> with are bundled in `AgentToolContext` (`sub_agent_scheduler.dart`) and passed
> as one object — the sketch below predates that and shows the fields spread out.

Behaves like synchronous delegation: spawns, awaits, returns the merged result as a
`ToolResult`. Schema (fan-out):

```jsonc
{ "delegations": [ { "agent": "research", "task": "find every call site of AgentSink" } ] }
```

```dart
Future<ToolResult> execute(input, {cancelSignal, onOutput}) async {
  final jobs = list.map((d) => scheduler.spawn(spec: catalog[d['agent']], task: d['task'],
      parentPolicy: parentPolicy, parentModel: parentModel, originConversationId: cid)).toList();
  // Awaits — but yields on the event loop, so other (detached) jobs keep progressing.
  final results = await Future.wait(jobs.map((j) => j.result));
  return ToolResult(_merge(list, results), isError: results.any((r) => r.isError));
}
```

Live progress still flows (the jobs emit on the bus → TUI renders `«label: → …»), so
await-driven is **not** a silent block.

### `dispatch` — detach / background (✅ shipped, phase 3)

Spawns without awaiting; returns handles immediately so the orchestrator can keep working
this turn and collect results in a later turn:

```jsonc
{ "delegations": [ { "agent": "research", "task": "…" } ] }
→ { "jobs": [ { "id": "j3", "label": "research", "status": "running" } ] }
```

### `collect` — gather results (✅ shipped, phase 3)

Pulls completed results (and pending status), explicitly — no mid-turn history mutation:

```jsonc
{ "job_ids": ["j3"] }     // omit → all completed jobs for this conversation
→ { "completed": [{ "id": "j3", "content": "…", "isError": false, "continuable": true }],
    "pending":  [{ "id": "j4", "label": "research", "status": "running" }] }
```

Finished single-agent jobs are flagged `(continuable)` (phase 4, `4df9a21`) so
the orchestrator knows it can `continue` them; composites and leaves that errored
before running aren't.

### `continue` — resume a prior job's conversation (✅ shipped, phase 3)

Send a follow-up message to a *completed* job's sub-agent, giving genuine multi-turn
main↔sub dialogue through tool calls. Spawns a new job seeded with the prior job's history
plus the message as the next user turn (a running job can't be continued — that would race
its current step; wait for `done` or `cancel` first):

```jsonc
{ "job_id": "j3", "message": "now also check the test files" }
→ { "job": { "id": "j7", "label": "research", "status": "running" } }
```

### `cancel` — stop a job by id (✅ shipped, phase 3)

```jsonc
{ "job_id": "j3" }
→ { "job_id": "j3", "status": "cancelled" }
```

### Result delivery fork (v1 / later)

- **v1: await-driven / pull.** `delegate` awaits; `dispatch`+`collect` pull on demand.
  History mutation is explicit and race-free.
- **Later: push / injection.** completed jobs auto-surface as system messages between turns,
  or get injected into the orchestrator's context. Powerful but racy (mutating history
  mid-turn while the agent reads it) — deliberately deferred.

## Pipelines as composite agents (ordered routing)

> **✅ Shipped** (phase 2): `AgentSpec.pipeline`/`role`/`isComposite`,
> `AgentCatalog.byRole`, and `SubAgentScheduler._runPipeline` (commits
> `055590f`, `07ff240`). Two corrections to the sketch below are noted in Status
> (7: composites don't hold a concurrency slot; 8: `maxDepth` backstop). The
> code is the source of truth; the sketch is retained as the design reference.

A **pipeline** is an ordered chain of designated role-agents that work flows through in
sequence — the ordered counterpart to `delegate`'s parallel fan-out. Rather than a separate
invocation mechanism, a pipeline is **an `AgentSpec` whose `pipeline` field is set** (a
composite agent). The main agent delegates to it like any agent (`delegate` to await, or
`dispatch` to detach), and the scheduler runs the chain instead of an LLM loop.

Example — a QA pipeline `qa`: implement → verify → test:

```dart
AgentSpec(
  name: 'qa',
  description: 'Run work through implement → verify → test, halting on a failed review.',
  pipeline: [
    PipelineStage(role: 'implementer', task: 'Implement the following.'),
    PipelineStage(role: 'verifier',    task: 'Review the implementation for correctness and edge cases.', haltOnFail: true),
    PipelineStage(role: 'tester',      task: 'Write and run tests for the implementation, addressing any review notes.'),
  ],
),
AgentSpec(name: 'implementer', role: 'implementer', toolNames: {'read','write','edit','bash'}),
AgentSpec(name: 'verifier',    role: 'verifier',    toolNames: {'read','grep','glob'}),
AgentSpec(name: 'tester',      role: 'tester',      toolNames: {'read','bash','grep'}),
```

### Execution

`spawn` branches on `spec.isComposite`. A leaf spec builds a provider + `Agent` and runs the
LLM loop; a composite spec runs the chain:

```dart
SubAgentJob spawn({...}) {
  final job = SubAgentJob(...);
  _runDetached(job, spec, task, parentPolicy, parentModel);   // acquires the semaphore; NOT awaited
  return job;
}

Future<DelegationResult> _runDetached(job, spec, task, parentPolicy, parentModel) async {
  await _semaphore.acquire();
  try {
    job.status = SubAgentJobStatus.running;
    return spec.isComposite
        ? await _runPipeline(job, spec, task, parentPolicy, parentModel)
        : await _runLeaf(spec, task, parentPolicy, parentModel);
  } finally {
    _semaphore.release();
  }
}

Future<DelegationResult> _runPipeline(job, spec, input, parentPolicy, parentModel) async {
  var ctx = input;                                       // accumulated handoff context
  for (final stage in spec.pipeline!) {
    final s = catalog.byRole(stage.role)
        ?? return DelegationResult.error('pipeline ${spec.name}: no agent for role ${stage.role}');
    final stageJob = spawn(spec: s,
        task: '${stage.task}\n\n--- prior work ---\n$ctx',
        parentPolicy: parentPolicy, parentModel: parentModel,
        originConversationId: job.originConversationId);
    job.emitStageStart(stage.role);                      // «qa: → verifier»
    final r = await stageJob.result;
    if (r.isError && stage.haltOnFail) return r;         // short-circuit (don't test broken code)
    ctx = r.content;                                     // each stage's output feeds the next
  }
  return DelegationResult(ctx);                          // final stage's output is the result
}
```

Semantics:
- **Sequential.** Stage N awaits stage N−1; order is enforced by the pipeline declaration, not
  the main agent's discretion. (Parallel fan-out remains `delegate`.)
- **Accumulated handoff.** Each stage gets its `task` plus the running context (prior stages'
  outputs). The pipeline result is the **final stage's output** (returning the whole accumulated
  document is a per-pipeline option for later).
- **Halt-on-fail.** A stage with `haltOnFail: true` whose result `isError` stops the chain, and
  that error becomes the pipeline's result. (A reviewer that wants to reject returns an error
  result; richer structured verdicts are a later option.)
- **Progress.** The pipeline-job emits a stage-transition line (`«qa: → verifier»`) on the bus;
  each stage-job then emits its own `«verifier: → …»`, so the nesting is visible.
- **Designation by role.** Stages name a `role`; the catalog resolves role → spec (`byRole`).
  v1 assumes one spec per role.
- **No model/tools of its own.** A composite spec orchestrates — it never calls an LLM and has
  no policy of its own. Each stage agent is independently fail-closed permissioned.
- **Nesting.** A stage role may resolve to another composite (a pipeline-of-pipelines);
  `maxDepth` caps it like any recursion. A pipeline must not list itself (directly or
  indirectly) as a stage.

## Permissions (fail-closed)

A sub-agent must not escalate privileges or interrupt the user.

- **Derived policy** (when `spec.policy` is null): `PermissionPolicy(defaults: parent.defaults
  with ask→deny, rules: parent.staticRules)`. Fresh `sessionRules` (no memory leaks across
  delegations). So a sub-agent can do exactly what the parent has already allowed statically
  or by builtin default — and nothing that would prompt.
- **Spec override**: a spec may supply its own `policy` (e.g. read-only `research`:
  `read`/`search`/`grep`/`glob` allowed, everything else denied).
- **The `delegate`/`dispatch` tools themselves**: allow them in the **main agent's** policy
  defaults (orchestration is the main agent's core capability; the sub-agent permission layer
  is the real gate). The fail-closed derivation means a sub-agent can only spawn further
  sub-agents if its spec explicitly grants the tool (see `_toolsFor`).

```dart
static PermissionPolicy _failClosed(PermissionPolicy p) => PermissionPolicy(
  defaults: p.defaults.map((k, v) =>
      MapEntry(k, v == PermissionDecision.ask ? PermissionDecision.deny : v)),
  rules: p.staticRules,
);
static final PermissionAsker _autoDenyAsker = (_) async => PermissionResponse.denyOnce;
```

## Models

`spec.model ?? parentModel`. The scheduler builds a fresh `LlmProvider` per job via
`buildProvider`, so different specs run different models against the same account context.
`null` inherits the active conversation's model.

## Result extraction + truncation

- On loop exit, read the final `Role.assistant` message's `TextBlock`s from the job-owned
  `history`. (`Agent.run({system, history, userInput, cancelSignal})` seeds one user message
  = `task`.)
- Truncate to `resultCharCap` (default 16 000 chars) with a `… (truncated)` marker.
- A leaf that didn't finish on an assistant text turn (ran out of steps, was
  cancelled, ended on a tool call) → `DelegationResult.error`, not a scavenged
  fragment.

> **✅ Now matches the sketch** (phase 4, `3358e94`): the answer comes only from
> the *last* message, and only if it is an assistant text turn. Earlier the
> scan walked backwards and would return a mid-reasoning preamble from an
> earlier turn when a job had run out of steps — silently wrong, status `done`.

## Cancellation scope — structured at the session level, detached at the turn level

- **Per-job**: `job.cancel()` completes that job's `Completer<void>`; its `agent.run` exits
  like today's ESC; `status → cancelled`.
- **Turn ESC** cancels the orchestrator's stream — **not** the detached jobs. A job launched
  in turn N keeps churning through turn N+1. That's the point.
- **Session/app scope**: a single `sessionCancelSignal` fans into every job; `cancelAll()`
  tears them all down on shutdown or session close. So teardown is orderly at the coarse
  scope while jobs are fire-and-forget at the turn scope.

## Concurrency cap

A semaphore gates `maxConcurrent` (default 6) live leaf sub-agents so a fan-out can't spawn 30
concurrent provider streams and trip rate limits or blow memory. Excess jobs sit in `queued`
until a slot frees. Composite jobs hold no slot (see correction 7) — only leaves consume the
resource it caps.

> **⚠ Known sharp edge — priority inversion.** The semaphore is plain FIFO, and
> the scheduler does not know whether a `spawn` is interactive (`delegate` — the
> orchestrator is awaiting, the user is blocked) or background (`dispatch` —
> fire-and-forget). If background jobs hold every slot, a later `delegate` parks
> in the queue behind them, so the turn the user is staring at waits for jobs
> they aren't watching. Because holding is non-preemptive (a running LLM call
> can't be paused), reordering the queue alone would not help when the pool is
> saturated — the fix is to reserve interactive headroom (cap background
> concurrency below `maxConcurrent`, or split the pool), which in turn needs
> `spawn` to carry an interactive/background flag it lacks today. Latency, not
> correctness; only under saturation. Listed under Known sharp edges in Status;
> deferred until Part II.

## Progress via the event bus (R5, promoted)

The `AgentEventBus` (implemented in `lib/agent/agent_event_bus.dart`)
becomes the **single live progress channel** for jobs. Each `SubAgentSink` emits labeled
events onto the scheduler's merged stream. The TUI subscribes and renders
`«{label}: → …»` for the active conversation (UI telemetry only — the orchestrator learns
about jobs through tool results, never the bus). This is also the hook for future
**token-budget roll-up / telemetry** across jobs.

## Nesting / recursion guard

A sub-agent gets the `delegate`/`dispatch` tools **only if** its `spec.toolNames` explicitly
includes them (or is `null` = all tools). A `maxDepth` (default 3) caps recursion regardless,
so a misbehaving agent can't spawn unboundedly. Nested spawns go through the same scheduler.

```dart
ToolRegistry _toolsFor(AgentSpec spec, int depth) {
  final base = spec.toolNames == null
      ? baseTools
      : ToolRegistry(baseTools.all.where((t) => spec.toolNames!.contains(t.schema.name)));
  final canDelegate = spec.toolNames == null ||
      spec.toolNames!.intersection({'delegate', 'dispatch'}).isNotEmpty;
  if (depth < maxDepth && canDelegate) {
    return ToolRegistry([...base.all, DelegateTool(this, depth: depth + 1)]);
  }
  return base;
}
```

## Wiring (post-decoupling, post-R2)

> **⚠ Superseded by v1** (see Status): the shipped wiring lives in
> `TuiCoordinator.create` and uses the **registry** (`registry.build`) instead of
> the `buildProvider`/`providerFactory` closure shown below; the scheduler is
> owned/disposed by the coordinator (not `SessionManager`); and nesting goes
> through the `delegateToolBuilder` hook. Since phase 4 the main agent's
> `withDelegateTool`/`withBackgroundTools` and the nesting builder all take a
> single `AgentToolContext` (built once), so the catalog/reference/policy/
> conversation/depth they share are no longer repeated. The sketch is retained
> for context.

The scheduler is **session-scoped** — owned by `SessionManager` (one per running app) and
disposed on shutdown. Constructed in `lib/tui_coordinator.dart`, where `providerFactory`, the
base tools, and the `AgentBuilder` (R2) already are.

```dart
// 1. Catalog (code-built for now): leaf agents (some role-designated) + composite pipelines.
final catalog = AgentCatalog([
  const AgentSpec(
    name: 'research',
    description: 'Read-only codebase exploration. Use for finding call sites, '
                 'summarizing subsystems, or answering "where/what" questions.',
    toolNames: {'read', 'search', 'grep', 'glob'},   // no write/edit/bash, no delegate
    // model: null  → inherits the active conversation's model
    // policy: null → fail-closed derived from the parent
  ),
  // Role-designated leaves for the QA pipeline:
  const AgentSpec(name: 'implementer', role: 'implementer',
      description: 'Implements code changes.', toolNames: {'read', 'write', 'edit', 'bash'}),
  const AgentSpec(name: 'verifier', role: 'verifier',
      description: 'Reviews work for correctness and edge cases.', toolNames: {'read', 'grep', 'glob'}),
  const AgentSpec(name: 'tester', role: 'tester',
      description: 'Writes and runs tests.', toolNames: {'read', 'bash', 'grep'}),
  // A composite pipeline the main agent can delegate to like any agent:
  const AgentSpec(
    name: 'qa',
    description: 'Run work through implement → verify → test, halting on a failed review.',
    pipeline: [
      PipelineStage(role: 'implementer', task: 'Implement the following.'),
      PipelineStage(role: 'verifier',    task: 'Review the implementation for correctness and edge cases.', haltOnFail: true),
      PipelineStage(role: 'tester',      task: 'Write and run tests for the implementation, addressing any review notes.'),
    ],
  ),
]);

// 2. Scheduler (session-scoped). provider builder wraps the existing providerFactory.
final scheduler = SubAgentScheduler(
  buildProvider: (model) => registry.build(config.provider, model, config.baseUrl),
  baseTools: tools,            // pure base tools
  catalog: catalog,
);

// 3. TUI subscribes to job progress for the active conversation.
scheduler.events.listen((e) => renderJobProgress(activeConversationId, e));

// 4. AgentBuilder (R2) builds the sink AND injects the per-conversation delegate tool.
Agent buildAgent({required conversationId, required provider, required chatRegion,
    required spinner, required policy, required asker}) {
  final sink = ChatAgentSink(chatRegion, spinner);   // or composing if the strip is active
  // The main agent always carries the spawn tools (it's a proactive spawner);
  // only sub-agents gate them via spec.toolNames.
  final agentTools = withDelegateTool(tools, scheduler,
      parentPolicy: policy, parentModel: provider.model, depth: 0);
  return Agent(
    provider: provider, tools: agentTools, sink: sink,
    policy: policy
      ..defaults['delegate'] = PermissionDecision.allow
      ..defaults['dispatch'] = PermissionDecision.allow,
    asker: asker, budget: config.buildTokenBudget(), maxSteps: config.maxSteps,
  );
}

// 5. Teardown: scheduler.cancelAll() + dispose() in SessionManager.closeAll().
```

`Agent` and `Conversation` are unchanged by this feature — the only new thing in the
orchestrator's tool registry is the `DelegateTool` (which closes over the scheduler + the
conversation's policy/model). The non-interactive `--prompt` path wires the same way;
delegation is agent-layer, not UI.

## Out of scope (explicit, for later)

- **Per-agent UI**: dedicated sub-panels / live per-agent views (the tool-strip work and
  beyond). v1 renders only the `«label: → …»` progress line + a jobs list.
- **Push / auto-injected results**: deferred (racy).
- **Token-budget roll-up**: sub-agents don't bind a `TokenBudget`; usage isn't summed into
  the main turn. The event bus is the future hook.
- **Persistence**: sub-agent turns aren't written to the session store. Only the main
  conversation is recorded; delegated answers survive as tool `ToolResultBlock`s.
- **Isolates / crash-isolation**: deferred (see async model).
- **Config-driven catalog / `/agents` command**: code-built for now.

## Files

> **⚠ Status** (see top): the files differ from the original plan —
> `SubAgentSink` is in its own `sub_agent_sink.dart`, `SessionManager` is
> **unchanged** (the coordinator owns the scheduler). The pipeline/composite
> phase added `pipeline`/`role` to `agent_spec.dart`; the background-tools phase
> added `lib/tools/background_tools.dart`; the phase-4 refactor added
> `lib/tools/delegation_base.dart` + `AgentToolContext` (in
> `sub_agent_scheduler.dart`).

### Shipped in v1 (new)

| File | Purpose |
|---|---|
| `lib/agent/agent_spec.dart` | `AgentSpec` (leaf: `reference`, `toolNames`, `policy`, `systemPrompt`, `maxSteps`) + `AgentCatalog` (name lookup) |
| `lib/agent/sub_agent_sink.dart` | `SubAgentSink` — emits `JobAgentEvent`s on the per-job bus |
| `lib/agent/sub_agent_scheduler.dart` | `SubAgentScheduler`, `SubAgentJob`, `DelegationResult`, `AgentToolContext`; leaf `spawn`, cancel, `maxConcurrent` cap, `delegateToolBuilder` hook |
| `lib/tools/delegation_base.dart` | `DelegationToolBase` — shared schema + delegation resolver + `spawnAll` (phase 4); extended by `delegate` and `dispatch` |
| `lib/tools/delegate_tool.dart` | `DelegateTool` (await, fan-out/merge) + `withDelegateTool` |

### Shipped in v1 (modified)

| File | Change |
|---|---|
| `lib/agent/agent_event_bus.dart` | `JobAgentEvent(jobId, label, event)` wrapper |
| `lib/tui_coordinator.dart` | Build catalog + scheduler; subscribe to job progress; inject `DelegateTool` via `withDelegateTool`; allow `delegate` in the main policy; dispose the scheduler in `_restoreTerminal` |

### Pending (not yet created)

| Area | Purpose |
|---|---|
| Nestable background tools | A `BackgroundToolBuilder` (akin to `delegateToolBuilder`) so sub-agents get `dispatch`/`collect`/`continue`/`cancel`, not just the main agent |
| Part II | `lib/agent/workflow.dart` (`WorkflowRun`), `lib/tools/conduct_tool.dart` |
| Catalog config | `/agents` command + config-driven catalog (ties to the registry's deferred config file) |

### Tests (4)

| File | Covers |
|---|---|
| `test/agent/sub_agent_scheduler_test.dart` | scripted fake `LlmProvider` + fake `buildProvider`: spawn returns immediately and `result` completes later; **fail-closed** denies an `ask` tool (never prompts); `toolNames` subset; `model: null` inherits; `maxConcurrent` queues excess jobs; `job.cancel()` → `cancelled`; `cancelAll()` tears down all. |
| `test/tools/delegate_tool_test.dart` | schema validates; fan-out awaits N jobs and merges; `isError` if any fails; orchestrator's `cancelSignal` propagates. |
| `test/tools/background_tools_test.dart` | `dispatch` returns distinct running handles (jobs reach `done`); `collect` partitions completed/pending and errors on unknown id; `continue` reseeds a finished leaf (prior turn + follow-up reach the provider) and rejects running/composite; `cancel` stops a running job and reports an already-finished job's status. |
| `test/agent/agent_sink_test.dart` (from Stage 4) | `SubAgentSink` emits labeled events on the bus. |

## Implementation order

> **✅ Tiers 1–4 shipped** (commits `c6bc813` → `9119620` → `0020ab0` →
> `3e28b9e`). The v1 critical path is the leaf + `delegate` subset: steps **1
> (prereq), 2a, 2b, 3, 5, 6**. Step **4 (composite pipelines)** and step **7
> (background tools)** have since shipped (phases 2 and 3).

> This is the linear *critical path*. The parallel breakdown — which steps different agents can
> build/test at once, keyed by file ownership — is in
> [Parallel implementation](#parallel-implementation-what-different-agents-can-build-at-once).
> The `[Tier N, Stream X]` tags below point into that section.

1. **Prereq (done):** Stage 4 (`AgentSink`) + R2 (`AgentBuilder`) + R5 (`AgentEventBus`)
   shipped — `Agent` takes `sink`, `lib/agent/` is UI-free, the bus exists. *(Caveat:
   `SubAgentSink` is **not** shipped — it is built in step 2b below, not a prerequisite.)*
2a. **[Tier 1, Stream A]** `AgentSpec` (role + pipeline/composite), `PipelineStage`,
    `AgentCatalog` (name + `byRole`).
2b. **[Tier 1, Stream B]** — runs *alongside* 2a: `SubAgentSink` (in `agent_sink.dart`) + the
    `AgentEvent` job-tag field (in `agent_event_bus.dart`) + `test/agent/agent_sink_test.dart`.
3. **[Tier 2]** `SubAgentScheduler` + `SubAgentJob` (+ `DelegationResult`) — unit-test leaf
   `spawn`/cancel/cap against a fake provider before any wiring. Needs **both** 2a and 2b.
4. **[Tier 3, Stream D]** Composite pipelines — the scheduler's `_runPipeline` branch + role
   lookup; unit-test the sequential chain, halt-on-fail, missing role, and the nesting cap.
5. **[Tier 3, Stream C]** `DelegateTool` (await) + `withDelegateTool` — unit-test
   fan-out/merge/cancel. Parallel with step 4 (different file; needs only the Tier 2 interface).
6. **[Tier 4]** Wire catalog + scheduler + delegate tool in `tui_coordinator.dart`; subscribe
   to progress; seed leaf specs and a `qa` pipeline.
7. (Later) `DispatchTool` + `CollectTool` (+ `continue`/`cancel`) for the background path.

## Parallel implementation (what different agents can build at once)

The critical path above is linear, but the work fans out wherever two streams own **different
files** and meet only at a type interface. Four tiers:

```
Tier 1 — parallel (independent leaves)
  ┌─ Stream A: lib/agent/agent_spec.dart
  └─ Stream B: lib/agent/agent_sink.dart        (+ SubAgentSink)
               lib/agent/agent_event_bus.dart   (+ job tag on AgentEvent)
        │              │
        └──────┬───────┘
               ▼
Tier 2 — single (serialization point; needs A + B)
   lib/agent/sub_agent_scheduler.dart   (leaf spawn / cancel / cap)
   test/agent/sub_agent_scheduler_test.dart
               │
        ┌──────┴───────┐
        ▼              ▼
Tier 3 — parallel (both need only the scheduler interface; different files)
   Stream C:               Stream D:
   lib/tools/              lib/agent/sub_agent_scheduler.dart
     delegate_tool.dart      (composite _runPipeline branch)
   test/tools/             + chain / halt / role tests added to
     delegate_tool_           sub_agent_scheduler_test.dart
     tool_test.dart
        │              │
        └──────┬───────┘
               ▼
Tier 4 — single (needs all)
   lib/tui_coordinator.dart + lib/session_manager.dart
```

| Tier | Stream | Owns (files) | Owns (tests) | Needs from |
|---|---|---|---|---|
| **1** | **A** | `lib/agent/agent_spec.dart` | catalog name / `byRole` lookup (a few assertions in the scheduler test, or a tiny standalone unit test) | nothing — pure data; imports only existing `PermissionPolicy` |
| **1** | **B** | `lib/agent/agent_sink.dart` (+ `SubAgentSink`), `lib/agent/agent_event_bus.dart` (+ a job `tag` on `AgentEvent`, or a `JobAgentEvent` wrapper) | `test/agent/agent_sink_test.dart` | shipped R5 bus + `AgentSink` interface |
| **2** | — | `lib/agent/sub_agent_scheduler.dart` (leaf `spawn`, `SubAgentJob`, `DelegationResult`, cancel, `maxConcurrent`) | `test/agent/sub_agent_scheduler_test.dart` | **both A and B** (catalog + sink + tagged events) |
| **3** | **C** | `lib/tools/delegate_tool.dart` (`DelegateTool` + `withDelegateTool`) | `test/tools/delegate_tool_test.dart` | the scheduler `spawn` / `job.result` interface + catalog (A) |
| **3** | **D** | `lib/agent/sub_agent_scheduler.dart` (composite `_runPipeline` branch + `byRole` resolution) | chain / halt-on-fail / missing-role / `maxDepth` cases in `sub_agent_scheduler_test.dart` | leaf scheduler (Tier 2) + catalog (A) |
| **4** | — | `lib/tui_coordinator.dart`, `lib/session_manager.dart` | manual + existing suite | everything above |

**Keeping parallel agents from colliding:**

- **One file, one owner per tier.** Every file is assigned to exactly one stream in its tier.
  The only file carried across tiers is `sub_agent_scheduler.dart` (Tier 2 creates it; Tier 3
  Stream D extends it) — and those tiers are *sequential*, never concurrent.
- **Each stream lands its own tests in isolation** (mock the downstream interface): B tests
  `SubAgentSink` against a real `AgentEventBus` with no scheduler; C tests `DelegateTool`
  against a fake `SubAgentScheduler`; D tests `_runPipeline` against a fake provider. No stream
  waits on another's tests.
- **Interface-first collapses Tier 2 + Stream C.** If Tier 2 first lands just the
  `SubAgentScheduler` / `SubAgentJob` / `DelegationResult` *signatures* (a stub `spawn`), Stream
  C can build and test `DelegateTool` against a fake scheduler **concurrently with** Tier 2's
  real implementation. Optional — the table above is the conservative critical path.
- **Catalog specs are data, not a stream.** The `research` / `implementer` / `verifier` /
  `tester` / `qa` `AgentSpec`s are plain object construction, authored during Tier 4 wiring.

## Verification

1. `dart analyze` clean; `lib/agent/` and `lib/tools/delegate_tool.dart` have no
   `tina_console` import.
2. `dart test` green, including the new test files.
3. Manual (`dart run bin/tina.dart`):
   - A normal turn is unchanged.
   - *"use the research agent to find every call site of `AgentSink`, then summarize"* →
     `delegate` fires, `«research: → …»` progress streams, the sub-agent runs its read-only
     subset, silently denies writes, and its answer returns as the tool result.
   - Ask for two delegations at once → concurrent, both answers merge.
   - ESC mid-delegation → the awaited jobs cancel, `[cancelled]` prints.
   - A sub-agent asked to write a file → denied by fail-closed policy, no prompt.
   - *"run this through the qa pipeline"* → implement → verify → test in order; `«qa: → …»`
     stage lines appear, each stage's output feeds the next, and a verifier rejection halts
     the chain.
   - (Later, with `dispatch`/`collect`) launch a background job, take another turn, then
     `collect` its result — confirm it churned across the intervening turn.

## Edge cases

| Case | Handling |
|---|---|
| **Job outlives its launch turn** | By design — `dispatch`ed jobs keep running; `collect` later. |
| **Background job still running at session end** | `cancelAll()` on shutdown/session close cancels it. |
| **Unknown agent name** | `spawn` returns a job whose `result` completes with `DelegationResult.error('unknown agent')`. |
| **Empty / no final answer** (max-steps, ended on a tool call) | `DelegationResult.error('${name} produced no final answer')`. |
| **Provider / stream error** in a sub-agent | `agent.run` surfaces via the bus; `result` completes with an error result. |
| **Oversized result** | Truncated to `resultCharCap` with `… (truncated)`. |
| **Sub-agent tries write/bash** | Denied by fail-closed policy (`ask`→`deny`); no prompt, no escalation. |
| **Recursion** | `delegate`/`dispatch` only on sub-agents whose spec grants them; `maxDepth` caps anyway. |
| **Pipeline stage role not in catalog** | The composite branch returns `DelegationResult.error('no agent for role …')`; the pipeline halts. |
| **Pipeline `haltOnFail` stage errors** | The chain short-circuits; that error is the pipeline's result. |
| **Composite spec also sets model/tools** | Invalid config — a composite spec sets only `pipeline`; leaf fields are ignored. |
| **Pipeline-of-pipelines / self-reference** | Nesting allowed (capped by `maxDepth`); a pipeline naming itself, directly or indirectly, is rejected at catalog-build time. |
| **Concurrency cap hit** | Excess jobs `queued`; run as slots free (semaphore). |
| **`collect` before a job is done** | Returned as `pending` (not completed). |
| **`continue` a running job** | Rejected — wait for `done`/`cancelled`; `continue` spawns a fresh job seeded from the prior job's history. |
| **Empty catalog** | `delegate`/`dispatch` not registered; orchestrator has no delegation capability. |
| **Passthrough / `--prompt`** | Works — delegation is agent-layer; sink routes to the passthrough surface. |
| **Active-conversation rendering** | Progress lines render only for the active conversation; background jobs still emit on the bus. |

---

# Part II — Adaptive workflows (the Conductor / Fugu-Ultra variant)

> **⏳ Pending** (see Status): none of this shipped. `WorkflowRun`, the `conduct`
> tool, and the `_runWorkflow` scheduler generalization are all future work that
> build on the shipped pipeline phase (ordered static DAGs).

> Source: *Sakana Fugu Technical Report* (Sakana AI, 2026), §3.2 + §4.4. This part specifies a
> **follow-on** to the v1 pipeline: instead of only *static* pipelines declared in the catalog,
> the orchestrator **emits query-adaptive workflows at inference time** through one tool, and the
> scheduler executes whatever DAG it draws.

## What Fugu adds

Fugu's two operating points map onto things tina already does — and one it doesn't yet:

| Fugu | tina analogue | Status |
|---|---|---|
| **Fugu** — latency-aware, route each query to the single best worker (no roles) | `delegate` to one specialist agent | v1 has this |
| **Fugu-Ultra** — compose a *workflow of multiple agents* per query, topology chosen per query | static `pipeline` catalog entries | v1 has this, **fixed** topologies only |
| **the Conductor** — the orchestrator *generates* the workflow (a DAG of steps) at run time | — | **this part** |

The gap Fugu-Ultra exposes: tina's pipelines are **hand-designed, fixed DAGs** declared in code.
Fugu-Ultra's contribution is that the topology itself is **generated per query as data**. Fixed
topologies (the current `qa` chain, any "Mixture-of-Agents"-style fixed synthesizer) are
"bottlenecked by that rigidity" — a fixed aggregator can't surpass itself on tasks outside its
expertise. The follow-on closes that gap.

tina's honest adaptation is a **prompted Conductor**: the main agent *plays* the Conductor role
through a `conduct` tool, using the `AgentCatalog` as its worker pool. It emits the workflow; the
scheduler is a dumb DAG executor. We get query-adaptive topologies **without training** — the
*learned* part of Fugu (SFT + sep-CMA-ES for Fugu; GRPO for Ultra) is out of scope; the main
agent's frontier capability + the tool schema stand in for it.

## The workflow primitive

Fugu-Ultra's entire expressiveness comes from **one data structure**: an *agentic workflow* is a
sequence of **steps**, where each step carries three fields —

1. **`subtask`** — a natural-language string (what this worker does).
2. **`agent`** — which worker runs it (tina: a catalog name, role, or explicit model).
3. **`access`** — a list of prior step ids whose **solutions** seed this worker's context.

That single primitive expresses every topology in §4.4:

| Topology | How the access list draws it |
|---|---|
| **best-of-N** | N steps, empty `access`, run in parallel; orchestrator picks or aggregates. |
| **sequential chain** | step k's `access: [k-1]`. (This is today's `pipeline`.) |
| **debate / aggregation (tree)** | leaves with empty `access`; a root step with `access: [leaves]` synthesizes. The **aggregator agent is chosen per query** — the Fugu-Ultra win over fixed synthesizers. |
| **build & debug** | builder step; debugger step with `access: [builder]`; optionally a re-build step with `access: [builder, debugger]`. |
| **bring in a specialist** | first-pass step; specialist step with `access: [firstPass]` that re-derives from first principles. |

A step's **solution** = its worker's `DelegationResult.content` (final assistant text, truncated to
`resultCharCap`). The access list gates *solutions*, **never** raw transcripts.

## The `conduct` tool

The orchestrator's single new tool. It takes a workflow and returns the sink step's solution.
Tool-mediated communication is preserved exactly: the orchestrator emits the DAG as a tool call and
reads the answer as a `ToolResult` — it never holds scheduler/job references, never subscribes to
the bus.

```jsonc
{
  "conduct": {
    "sink": 3,                          // which step's solution is the workflow's answer
    "steps": [
      { "id": 1, "agent": "research",    "subtask": "Find every call site of AgentSink.",         "access": [] },
      { "id": 2, "agent": "research",    "subtask": "Same, independent attempt.",                 "access": [] },
      { "id": 3, "agent": "synthesizer", "subtask": "Reconcile the two lists into one, deduped.", "access": [1, 2] }
    ]
  }
}
```

```dart
Future<ToolResult> execute(input, {cancelSignal, onOutput}) async {
  final run = WorkflowRun.parse(input['conduct']);          // validates DAG, sink, access ids
  final result = await scheduler.runWorkflow(run,
      parentPolicy: parentPolicy, parentModel: parentModel,
      originConversationId: cid, cancelSignal: cancelSignal);
  return ToolResult(result.content, isError: result.isError);
}
```

`dispatch`/`collect` get the same treatment later: a **detached workflow** returns a job handle
whose `result` is the sink solution, churning across turns.

## Workflow execution — a DAG on the existing scheduler

`_runPipeline` (linear chain) generalizes to `_runWorkflow` (DAG). A step becomes runnable when
every id in its `access` is solved; runnable steps fan out up to `maxConcurrent`. Each step spawns a
sub-agent job exactly like `delegate` does today — same provider build, fail-closed policy,
`SubAgentSink`, bus events (`«workflow: → synthesizer»`).

```dart
Future<DelegationResult> _runWorkflow(WorkflowRun run, ...) async {
  final results = <int, DelegationResult>{};               // step id -> solution
  final pending = [...run.steps];
  while (pending.isNotEmpty) {
    final ready = pending.where((s) => s.access.every((d) => results.containsKey(d))).toList();
    if (ready.isEmpty) {                                   // cycle / dangling access id
      return DelegationResult.error('unresolvable workflow deps: ${pending.map((s) => s.id)}');
    }
    final stageJobs = ready.map((s) {
      final ctx = s.access.map((d) => '# Step $d\n${results[d]!.content}').join('\n\n');
      return _spawnStep(s, task: '${s.subtask}\n\n--- referenced work ---\n$ctx', ...)
          .then((r) { results[s.id] = r; pending.remove(s); });
    }).toList();
    await Future.wait(stageJobs);                          // semaphore caps actual concurrency
  }
  return results[run.sink] ?? DelegationResult.error('workflow produced no sink step');
}
```

- **Topological, not linear.** Independent steps run concurrently; dependent steps wait on their
  access list only.
- **Progress.** The workflow-job emits a step-start line per branch; each step-job emits its own
  `«agent: → …»`, so trees are visible.
- **Error propagation.** A step that errors is recorded as an error solution; a dependent step whose
  `access` includes an errored prerequisite is errored too **unless** declared `skipOnFail: true`
  (mirrors pipeline `haltOnFail`, inverted: default is to halt the branch).

## Intra-workflow isolation (prevent orchestration collapse)

This is Fugu-Ultra §3.2.2's load-bearing idea, and **tina already has it by construction** — each
sub-agent job owns its own transcript and never sees a sibling's. The refinement is to *keep* it
that way and make the access list the **only** inter-agent channel:

- A step's worker sees: its `subtask` + the **solutions** of its `access`-listed steps. Nothing else.
- It does **not** see another step's tool-call transcript, reasoning, or intermediate tool output —
  only that step's final answer, and only if accessed.

**Orchestration collapse**, in tina terms: if a builder agent were handed a researcher's
*scratchpad*, the builder would just continue the researcher's trajectory and add nothing. Passing
only accessed *solutions* is what lets the builder take its own path. The current pipeline's
`--- prior work ---` concatenation already passes solutions not transcripts, but it passes **all** of
them; the access list makes the handoff **selective**, which is what unlocks debate/aggregation (a
synthesizer seeing *two independent* attempts, not one accumulated thread).

## Persistent shared memory (the other half of §3.2.2)

Isolation within a workflow must be paired with **sharing across** the conversation, or agents
redundantly re-discover the same artifacts (re-grep the same call sites, re-read the same files).
Fugu-Ultra splits memory into two layers; tina maps them onto what it already shares:

| Fugu-Ultra layer | tina realization |
|---|---|
| **Intra-workflow isolation** (within one workflow: reasoning transcripts per-agent, access-gated) | Per-job history; access list gates solutions. *(already true)* |
| **Inter-workflow shared memory** (across the conversation: environment/tool memory shared) | The **shared filesystem** + conversation-scoped artifact store — all agents operate on the same working tree, so a file one agent wrote is there for the next. |

The rule, made explicit: **agent *reasoning* is isolated; the *environment* (files, tool
side-effects, conversation artifacts) is shared.** A `conduct` workflow composes cleanly on top of
`continue`/multi-turn: a later workflow's agents inherit the filesystem state the earlier one
produced, but start fresh reasoning — exactly Fugu-Ultra's "full memory over conversation state,
isolated within the current workflow."

## Static pipelines become *named* workflows

With `conduct` in place, a catalog `pipeline` is no longer a special composite kind — it's a
**named, reusable workflow** the orchestrator can delegate to (or inline). `PipelineStage` gains an
optional `access` (default `[prev]`, preserving today's chain semantics); `isComposite` means "this
catalog entry *is* a `WorkflowRun`." One executor serves both:

- **Static** — `AgentSpec.pipeline` declares the DAG in code (`qa`, a review-gate). Declared once,
  reused; good for structure/policy you want guaranteed.
- **Dynamic** — the orchestrator draws the DAG per query via `conduct`. Good for topologies that
  depend on the task.

`delegate`-to-a-pipeline and `conduct` both end at `_runWorkflow`; the only difference is who
authored the steps.

## Files (Part II)

### New (3)

| File | Purpose |
|---|---|
| `lib/agent/workflow.dart` | `WorkflowRun`, `WorkflowStep` (`id`, `agent`, `subtask`, `access`, `skipOnFail`), parse + DAG validation (acyclic, sink exists, access ids resolve). UI-free. |
| `lib/tools/conduct_tool.dart` | `ConductTool` (await; returns sink solution) + `DispatchWorkflowTool` (later). Mirrors `DelegateTool`. |
| `test/agent/workflow_test.dart` | DAG exec: parallel branches, access-gated context, sink selection, cycle/dangling-id rejection, errored-prerequisite propagation, `maxConcurrent` interleaving. Fake provider. |

### Modified (2)

| File | Change |
|---|---|
| `lib/agent/sub_agent_scheduler.dart` | Add `runWorkflow(WorkflowRun, …)` (`_runWorkflow`) generalizing `_runPipeline`; `_runPipeline` becomes `pipeline → WorkflowRun` + `_runWorkflow`. |
| `lib/agent/agent_spec.dart` | `PipelineStage.access` (default `[prev]`); `AgentSpec` exposes its pipeline as a `WorkflowRun`. |

## Implementation order (Part II, after v1 ships)

1. `WorkflowRun`/`WorkflowStep` + parse/validation (unit-test acyclic/sink/access before anything runs).
2. `runWorkflow` on the scheduler; **refactor `_runPipeline` onto it** (chain = each stage
   `access:[prev]`). Existing pipeline tests must stay green — that's the safety net.
3. Access-gated context (pass only listed solutions, not the accumulated thread). Add an isolation
   test: a step's worker never receives a non-accessed sibling's output.
4. `ConductTool` (await) — unit-test the debate/aggregation topology (two leaves + synthesizer) and
   best-of-N.
5. Wire `conduct` into the main agent's tool set (alongside `delegate`); allow it in the main policy.
6. (Later) `DispatchWorkflowTool` + per-branch workflow progress rendering (`«workflow: → role»`).

### Parallel implementation (Part II)

Part II has less fan-out than v1 — its spine is a single-file scheduler refactor — but two
seams are independent enough to hand to separate agents:

- **`workflow.dart` is a pure leaf** (`WorkflowRun` / `WorkflowStep` + parse/DAG validation).
  Build and unit-test it (acyclic, sink exists, access ids resolve, cycle/dangling-id
  rejection) **in parallel with everything else** — it depends on nothing and its tests need no
  scheduler. This is the cleanest split-out.
- **`ConductTool` can ride a stub.** Once `WorkflowRun` exists, `lib/tools/conduct_tool.dart`
  can be built and tested against a fake `scheduler.runWorkflow` **concurrently with** the real
  `runWorkflow` / `_runPipeline` refactor in `sub_agent_scheduler.dart` (different files). The
  small `agent_spec.dart` change (`PipelineStage.access`, expose-pipeline-as-`WorkflowRun`)
  must land just *before* the scheduler refactor — the refactor needs it to convert a catalog
  pipeline into a `WorkflowRun` — so sequence those two even though they're separate files.

So the Part II critical path is `workflow.dart` → `agent_spec.dart` change → `_runWorkflow` +
`_runPipeline` refactor (keep existing pipeline tests green) → wire `conduct`. The two parallel
opportunities are the validation leaf up front and the `ConductTool`-against-a-stub alongside
the scheduler work.

## Verification (Part II)

1. `dart analyze` clean; `lib/agent/workflow.dart` and `lib/tools/conduct_tool.dart` have no
   `tina_console` import.
2. `dart test` green, including `workflow_test.dart`; **existing pipeline tests unchanged**
   (the refactor is behavior-preserving for chains).
3. Manual (`dart run bin/tina.dart`):
   - *"research call sites of AgentSink two independent ways, then merge the lists"* → `conduct`
     emits leaves + synthesizer; both leaves run concurrently, synthesizer waits on `access:[1,2]`;
     final answer is the merged list.
   - *"build it, then have someone else review for bugs, then fix"* → build → debug
     (`access:[build]`) → rebuild (`access:[build, debug]`) chain.
   - An orchestrator that names a non-existent step id in `access` → clean error result, no hang.
   - A cyclic `access` (`1→2→1`) → rejected at parse, error result.
   - `delegate` to the existing `qa` pipeline still works unchanged.

## Edge cases (Part II)

| Case | Handling |
|---|---|
| **Cyclic access list** (`1→2→1`) | Rejected at `WorkflowRun.parse`; `conduct` returns an error result. |
| **Dangling access id** (references a step not in the workflow) | Rejected at parse. |
| **No `sink` named** | Default to the unique topological sink if exactly one exists; else parse error (ambiguous). |
| **Multiple topological sinks** | Orchestrator must name `sink`; else rejected (ambiguous). |
| **Errored prerequisite** | Dependent step is errored too unless declared `skipOnFail: true`. |
| **Orchestration collapse** (worker sees too much) | Prevented by construction: only accessed *solutions* seed context. |
| **Redundant re-discovery across turns** | Mitigated by the shared filesystem (inter-workflow memory); reasoning stays isolated. |
| **Very wide fan-out** | `maxConcurrent` semaphore serializes; excess steps queue. |
| **Orchestrator-as-worker** (Ultra allows the orchestrator itself as a worker) | Allowed: `agent` may name the main conversation's model; spawns a fresh sub-agent (no shared transcript). `maxDepth` still caps nesting. |
| **Detached workflow at session end** | `cancelAll()` tears it down like any job. |

## Out of scope (Part II)

- **Trained orchestration** — SFT routing labels, sep-CMA-ES, GRPO. tina's conductor is
  *prompted*, not *learned*. The tool schema + system prompt are the only "policy."
- **Auto-learned topologies / policy reuse** — no offline workflow optimization or experience replay.
- **The Fugu single-worker *routing head*** as a cheap pre-classifier — a `route` tool / router agent
  that picks one specialist to avoid spinning up a workflow for easy tasks is a natural later layer;
  v1 lets the orchestrator simply `delegate` to one agent when a workflow isn't warranted.

---

*Architecture credit: Sakana AI, "Sakana Fugu Technical Report" (arXiv:2606.21228). This part
adapts the **Conductor** workflow primitive (§3.2.1), the **intra-workflow isolation /
inter-workflow shared memory** model (§3.2.2), and the emergent **topologies** (§4.4) to tina's
existing scheduler — as a prompted (not trained) conductor.*
