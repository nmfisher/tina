# The default chat workflow

Since v0.1.3, every normal chat turn routes through an editable DOT workflow at
`~/.tina/workflows/default.dot` while that file exists (seeded from
`kDefaultWorkflowDotSource` in `lib/pipeline/default_workflow.dart`). This doc
describes the seeded graph, the design decisions behind it, and the engine
primitives it relies on.

## The flow

A turn walks this graph from `start` to `done`:

```
start
  └─> main                talk with the user + explore the repo
        └─> plan          develop the plan, hand it to the first reviewer
              └─> plan_review_1   review: approve / revise / clarify
                    │              (clarify ─> human gate ─> back to a review)
                    └─ approve ─> plan_review_2   a FRESH second pass
                                      │
                                      └─ approve ─> fanout
                                            ├─> exec_1  ┐
                                            ├─> exec_2  ┤ parallel
                                            ├─> exec_3  ┘
                                            └─> fanin   merge the results
                                                  └─> exec_reviewer   review the result
                                                        └─> done
```

`main`, `plan`, `plan_review_*`, the executors, and `exec_reviewer` are `box`
(codergen) nodes that each carry their own `system_prompt` (identity) and
inherit the conversation's model unless they set `llm_model`/`llm_provider`.
Routing between nodes is verdict-driven: a reviewer ends its response with a
`VERDICT: <label>` line, which the engine matches against an outgoing edge's
`label`. `main` and the executors can also delegate sub-agents with the
`delegate` tool (a task plus an optional tool profile: `read-only` for
exploration/review, `full` for changes).

## Design decisions

### Double review — two sequential nodes, one identity

The plan is reviewed twice by the same reviewer identity. The simplest
expression that works is **two sequential nodes** (`plan_review_1` and
`plan_review_2`) that share one `system_prompt`:

- `plan_review_1 --approve--> plan_review_2`
- `plan_review_2 --approve--> fanout`

Because **each node visit is already a fresh one-shot agent** (the engine asks
the scheduler to build a new `Agent` for that one turn and drop it — see
`docs/proposals/node_handoff_design.md` §7), the second pass is automatically
fresh. No per-node visit counter or condition is required.

The alternative — a single reviewer node with a self-loop plus a per-node visit
counter exposed to edge conditions — was rejected: it needs new engine surface
(a counter observable from `condition` expressions) for no benefit, since
freshness already comes for free from the one-shot-agent-per-visit model.

### Revise loops to a fresh review, not back to the plan node

The reviewer **updates the plan itself**: when it revises, it outputs the full
revised plan as its node output. So `revise` loops to a fresh pass of the *same*
review node, not back to `plan`:

- `plan_review_1 --revise--> plan_review_1`
- `plan_review_2 --revise--> plan_review_2`

The plan therefore evolves as a **chain of revisions carried forward in each
downstream node's preamble** (the engine renders prior node outputs as
`--- <nodeId> ---` sections in front of the next prompt). Each reviewer is told
to treat the most recent revision as the current plan. No special context-key
remapping is needed — the existing preamble mechanism carries it. The
back-edge is a plain edge, so the loop is bounded only by the reviewer
eventually approving; a reviewer prompt that caps revisions (e.g. "approve with
caveats after two revises") is the mitigation.

### Clarification goes through the human gate

`plan_review_1` (and `plan_review_2`) may emit `VERDICT: clarify`, which routes
to the `clarify` node — a `hexagon` (human gate). The gate presents its
outgoing edges as choices ("Re-review with this in mind" / "Approve and
continue") and routes on the user's pick, looping back to a review. In headless
mode the interviewer auto-picks the first option, so the workflow never blocks.
The gate's question is the node's static `label`; a **dynamic, free-form
clarification question** (the reviewer's specific question, surfaced as the
gate prompt) is future refinement — today the reviewer states its question in
its streamed output and the gate asks how to proceed.

## Parallel fan-out and fan-in

The step from "approved plan" to "executed work" is the engine's parallel
fan-out, implemented by two handlers (the shapes are mapped in
`packages/attractor/lib/src/graph.dart` → `shapeToHandlerType`):

- **`ParallelHandler`** (`shape=component`, type `parallel`) — fan-out.
- **`ParallelFanInHandler`** (`shape=tripleoctagon`, type `parallel.fan_in`) — fan-in.

The `fanout` node's outgoing edges are partitioned into **branches** (every
target that is not a fan-in node — here `exec_1`, `exec_2`, `exec_3`) and a
single **convergence** (the one `tripleoctagon` target — `fanin`). The handler:

1. **Clones the run `Context` per branch** (`Context.clone`), so a branch's
   writes never leak into a sibling's context.
2. Runs every branch **concurrently** (`Future.wait`), each as a single node
   via the handler registry (so a `box` executor runs under the same codergen
   handler as anywhere else).
3. **Stages** each branch's output under `internal.parallel.<fanout>.branch.<id>`
   keys (the `internal.` prefix means the preamble skips them) plus a branch
   list, and routes the engine to the fan-in node via
   `Outcome.suggestedNextIds`.

The `fanin` node's handler finds its fan-out predecessor (the incoming edge
whose source resolves to a `parallel` handler), reads that predecessor's staged
branches, and **merges them into one result** under its own node id — so the
next node's preamble sees a single `--- fanin ---` block instead of N internal
keys. A failed branch is surfaced as text inside the merge (the fan-out itself
still succeeds), so the execution reviewer can judge it rather than the whole
run aborting.

The executors divide the work statically: the `plan` node is told to split the
work into up to three independent chunks labeled `[1]`, `[2]`, `[3]`, and each
executor takes exactly one chunk. If the plan has fewer chunks, the extra
executor idles.

### Limitations (documented)

- Each branch is a **single node** (the edge's immediate target). Model a
  multi-step branch as that executor delegating internally with the `delegate`
  tool.
- One fan-in convergence is supported per fan-out (the first `tripleoctagon`
  successor); the fan-in reads only its own predecessor's staged branches.
- Per-branch progress is **not** emitted as engine `node_started`/`node_completed`
  events (branches stream through their own sink); only the `fanout` node itself
  appears in the event stream. Each branch is still recorded in the run store's
  audit trail.
- The reviewer→executor chunk assignment is static (three executors, three
  chunks). Adjust the node count in the DOT to change it.

## Explore is a placeholder

`main` explores the repository using its file tools (read, grep, glob, bash,
search) and read-only delegation via the `delegate` tool — every node agent
already runs with the full tool profile plus `delegate`
(`SubAgentScheduler.runStandalone`). This is the **minimal** explore capability
for now. A dedicated explore node or a first-class read-only `explore` tool
(matching the `Explore` agent the host UI exposes) is future refinement; the
`main` node's `system_prompt` is the place that behaviour is expressed today.

## Editing and disabling

- **Edit:** `/workflow edit default` opens the visual node editor on the seed
  graph. The graph serializes back through `graphToDot`, so hand-edits to the
  `.dot` file round-trip.
- **Disable:** delete `~/.tina/workflows/default.dot`, or set
  `[default] workflow = "none"` in `~/.tina/config`, to fall back to the plain
  single-agent path.
- **Fallbacks:** a missing, unparseable, or invalid `default.dot` shows a
  warning and falls back to the plain agent (chat never bricks); a runtime
  failure ends the turn like any failed turn.

## See also

- `docs/features/agent_pipeline.md` — the agent/sub-agent model and the
  `delegate` tool.
- `docs/proposals/node_handoff_design.md` — node vs agent, per-node system
  prompts, and the handoff primitives (`VERDICT` edges, `suggestedNextIds`).
- `packages/attractor/` — the DOT pipeline engine: `graph.dart` (shape → handler
  type), `engine.dart` (edge selection), `handlers/parallel_handler.dart`
  (fan-out / fan-in).
