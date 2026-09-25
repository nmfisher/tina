# Proposal: hierarchical classifier traversal over the active conversation

Status: proposal, not implemented. Supersedes the earlier version of this
document (kept as `workspace_questions.md.orig` and in `~/.tina/backups/`).
It is a handoff brief: an agent or human should be able to implement it
without further design work.

## Why

Today only user submissions can be inspected before they reach the agent, and
the two classifiers that run on them (`GitInput`, `IntentInput`) are flat,
one-shot annotators: they tag the message and pass it on. They cannot branch,
nest, or act. So a cheap, known question — "did the user ask for a git
commit?" — still goes to the main agent, which thinks about it and comes back
with a commit plan, when a classifier could have intercepted it for a fraction
of the cost.

We want an architecture that:

- feeds a bounded subset of the **active conversation** into classifiers;
- runs classifiers as a **tree**: each node classifies, then branches into
  child nodes based on its answers;
- triggers from **user messages and assistant turns** (or a combination);
- lets a branch take an action — annotate, notify, or intercept the message so
  it never reaches the agent.

## Scope

**In scope: the traversal engine.** Tree definition, condition evaluation,
recursive execution, state, triggers, cancellation, status.

**Out of scope (later, built on this):**

- The content of the classifiers. We will grow a library of them
  incrementally. One known example (git-commit detection) already exists as
  `GitInput` and becomes a template for content, not engine code.
- What concrete actions do at a branch. The engine defines the action types
  only; plugging in real actions (run a command, spawn an agent) is future
  work.
- The `/index` classifier architecture will connect to this later. Do not
  couple to it now.
- The old plan's `/classifier-review` confirm/store/overlay flow. Once the
  engine exists, a confirmed question set is just one possible *definition
  source* for a tree (see E4). Build the seam, not the source.

## What already exists (build on it, don't rebuild)

- **User-message pipeline** — `packages/tina_app/lib/src/execution/input_routes.dart`.
  Every admitted submission passes through `InputProcessor` plugins in
  registration order. A processor can return `pass`, `replace`, `route` to a
  named `InputHandler` (full interception — the agent never sees the message),
  or `stop`. Decisions carry frozen JSON `data` that later processors and
  handlers can read. `prepare()` runs before queue admission;
  `deliver()` runs handlers in turn order (call sites in
  `packages/tina_app/lib/src/execution/turn_executor.dart` around lines 122
  and 400).
- **Classifier executors to copy** — `intent_input.dart` (same directory) is
  the template: background run per admitted input, newest-wins per
  conversation, 15s timeout, `StatusSource` phases checking → ready /
  unavailable / cancelled, results published after the invocation handoff.
  `git_input.dart` is the same pattern plus status rendering.
- **Judgment service** — `package:classifier` (`JudgmentService`,
  `MeteredJudgmentService`, `JudgmentCancellation`, request budgets). All
  model calls must go through the metered service and the spend ledger, like
  `configuredGitInputPlugin` in `lib/composition/git_input.dart` does.
- **Status strip** — `StatusSource` + `Renderer` contributions render under
  the input line (see `docs/features/input_routing.md`).
- **Agent events** — `packages/tina_engine/lib/src/agent/agent_event_bus.dart`
  publishes `AgentEvent`s. Check whether turn completion is already observable
  there before adding any new seam (E2).

What does **not** exist: the tree, the recursion, condition-gated children,
shared traversal state, and any assistant-side trigger. That is the work.

## Design

### Tree definition

A traversal spec is plain JSON (versioned, canonical-JSON + fingerprint like
the previous proposal's `canonicalJson`, so anything can cache on it):

```text
TraversalSpec {
  id, version
  root: Node
}
Node {
  id                      // unique, snake_case
  classifier: questions   // judgment questions for this node
  run: background|blocking
  children: [ Edge ]      // optional
}
Edge {
  when: condition | absent = always
  then: node id | action
}
Condition: dotted-path lookup in traversal state; operators
equals / notEquals / present / absent / greaterThan / lessThan.
A malformed comparison evaluates to false and never throws.
```

Validation: unique ids, acyclic edges, children exist, depth cap (4), node cap
per traversal (8). Invalid spec → inert engine plus a diagnostic, never a
crash.

### Traversal

1. Start at the root with a state object: `{facts: {}, meta: {...trigger
   info}}`.
2. Run the node's classifier against the conversation window. Answers go into
   state as `q_<nodeId>.<questionId>`.
3. Evaluate child edges **in order**. Recurse into each satisfied child.
   Because the engine recurses, a child always sees its parent's answers in
   state — the previous proposal's two-phase flatten becomes unnecessary.
4. Enforce per-node timeout, total-traversal budget, and cancellation (Esc)
   at every step.
5. When an edge points at an action instead of a node, record the action in
   state and stop that branch.

### Actions (engine-level types only; v1)

- `annotate` — merge values into the traversal state for later traversals and
  status. Default; never affects the turn.
- `notify` — surface a line on the status strip.
- `intercept` — **user-message traversals only**: act before the agent. v1
  proves it with a test handler; real handlers come later.
- `noop`.

A leaf with no action behaves as `annotate`.

### Triggers

- **User message** (exists): an adapter implements `InputProcessor`. Two
  modes, chosen by the spec: `background` (pass immediately, classify
  alongside, like `IntentInput`) and `blocking` (await the traversal, then
  pass with data or `route`/`stop` if an `intercept` fired). Blocking is the
  only mode where interception is possible.
- **Assistant turn** (new, background only): when a turn completes — history
  grew with a non-empty assistant text message, see the end of
  `TurnExecutor._runTurn` — start a background traversal. Its results can
  annotate or notify only; transforming a response that is already on screen
  is out of scope. Use the existing `AgentEventBus` if it already exposes
  this; otherwise add a minimal turn-completed observer.
- **Re-entry guard**: a traversal must never trigger a traversal (its own
  model calls and annotations are invisible to triggers).

### State and lifecycle

- Per conversation, in memory only (no checkpoints — same decision as before).
- One traversal per conversation at a time per trigger kind; a newer trigger
  cancels the older run (newest-wins, `IntentInput` pattern).
- The conversation window fed to classifiers is bounded: current text, last N
  messages, text blocks only — same shape as `InputTextSource` today.
- Empty or missing spec → engine is inert. TypeSafe unconfigured or ledger
  missing → inert. Headless (`interactive: false`) → inert, same self-gating
  as `configuredGitInputPlugin`.

### Definition loading (the later-expansion seam)

`TraversalSpecSource` interface with `load()` + `changes`. v1 ships exactly
one implementation: a JSON file loader (lenient — unreadable or corrupt file →
inert + diagnostic) plus an in-code default spec used by tests. Later,
`/classifier-review` confirmed sets, the index architecture, or hand-written
libraries plug in here without engine changes.

## Workstreams

Order: E0 → E1 ∥ E2 → E3 → E4. E1 proves the commit-interception scenario end
to end; nothing after E0 is speculative.

Parallelization (two waves):

- **Wave 1, fully disjoint — E0, E2-seam, E3-renderer.** E0 owns
  `packages/classifier/**`. The E2 seam (turn-completed event) owns
  `packages/tina_engine/**` and does not need E0 at all — check
  `AgentEventBus` first; if it already publishes turn completion, this track
  is zero code. The E3 status model + renderer can be built against the
  pinned status shape alone (see `IntentStatus` / `GitStatusRenderer`) and
  wires to real publishers in wave 2.
- **Wave 2, after E0 — E1, E2-adapter, E3-wiring, E4 in parallel.** All four
  consume only E0's types/runner; E4 needs `spec.dart` only, not the runner.
- **Serialization points:** the composition plugin list (E1, E2-adapter and
  E3 all append registrations there — the one real merge surface), the
  classifier barrel export, and fixture/default specs (fixtures live in test
  helpers only). E1 is the acceptance gate: wave 2 is not done while it is
  open.

Packaging: the pure core (E0) lives in **`package:classifier`**, not in a new
package and not in `tina_app`. It is a sibling of the existing judgment
runners (`batch_runner.dart`, `request_packer.dart`, `request_budget.dart`),
needs nothing beyond the judgment models, and keeps `classifier`'s
no-direct-I/O rule intact — the runner records actions as data and never
performs them. A new standalone package is not justified: no second consumer
exists yet, and `tina_app` would keep its `classifier` dependency either way.
All adapters (E1–E4) stay in `tina_app`, which already depends on
`classifier`. When the `/index` architecture connects later, it can consume
the runner directly.

### E0 — traversal engine core

`packages/classifier/lib/src/traversal/` — `spec.dart` (types, JSON decode,
`validateSpec`, canonical JSON, fingerprint), `conditions.dart`,
`runner.dart`; export via the judgments barrel:

- Spec types + JSON decode + `validateSpec` + canonical JSON + fingerprint.
- Condition evaluation (port the semantics designed in the superseded
  proposal: dotted path, six operators, malformed = false).
- Recursive runner: takes a spec, a `JudgmentService` (metered), a
  conversation window, and a `JudgmentCancellation`; returns the final state
  and recorded actions. Enforces depth/node caps, per-node timeout, total
  budget, cancellation at every await.
- No plugin wiring here — pure logic.

Tests: branch-taken and branch-skipped matrices, depth and node caps,
malformed condition = false, cancellation mid-tree, empty spec = zero model
requests, fingerprint stability. These land in `packages/classifier/test`
alongside the existing judgment-runner tests.

### E1 — user-message trigger adapter (proves interception)

`packages/tina_app/lib/src/execution/classifier_tree_input.dart`, modeled on
`intent_input.dart`:

- `InputProcessor` that starts a traversal per admitted input; modes and
  newest-wins per the design section; 15s per node default timeout.
- Background mode: `InputDecision.pass(data: {...state})` after the traversal
  settles.
- Blocking mode: await, then pass with data — or, if the traversal recorded
  `intercept`, return `InputDecision.route(...)` / `stop(...)`.
- Ship a **test-only** `InputHandler` fixture (e.g. handler id
  `test.commit-handler`) that answers without the agent.
- Register plugin ids `tina.classifier-tree` / `.status` next to the
  git/intent plugins in `lib/composition/`; requires `spendLedgerServiceKey`.

Acceptance scenario: with a two-node fixture spec (root "is this a git
request?" → child "is it a commit?" → `intercept`), submitting "commit this
please" produces the handler's reply, no agent turn, and the spend ledger
shows classifier-sized charges only.

Tests: mirror `intent_input_test.dart` — phases, newest-wins, background vs
blocking, intercept routing, inertness when spec empty or service missing.

### E2 — assistant-turn trigger seam

- Check `AgentEventBus` first; if turn completion is already published,
  subscribe. Otherwise add a minimal observer: after `TurnExecutor._runTurn`
  finishes a turn with a non-empty assistant text message, publish an event
  carrying `(conversationId, message count, last assistant text length)`. No
  message bodies in the event — the adapter re-reads the conversation window
  itself.
- Adapter starts a background traversal (annotate/notify only). Same
  newest-wins and budget rules. Guard against re-entry.

Tests: fires once per completed turn; aborted/cancelled turns handled
deliberately (pick a rule and pin it); re-entry guard; no trigger from
traversal activity.

### E3 — status rendering

- One `StatusSource` for traversal progress/results: phases checking → ready
  / unavailable / cancelled, keyed by conversation, newest-wins.
- One `Renderer` drawing a compact trail, e.g. `◆ git:yes · commit:yes`, dim
  on cancel/unavailable.

Tests: renderer golden, phase transitions, stale result suppression.

### E4 — definition source seam

- `TraversalSpecSource` interface (`load()` + `changes` stream) + JSON file
  loader (lenient) + in-code default spec.
- A source change cancels the running traversal and swaps the spec; invalid
  spec → previous spec stays active, diagnostic shown.

Tests: lenient load (missing file, corrupt JSON, invalid tree), live swap.

## Verify

- `dart analyze` clean.
- Green: `packages/tina_app/test/{application,classification,execution}`,
  `packages/tina_engine/test`, plus any suite a touched file belongs to.
- Manual smoke: submit a commit-style prompt with the E1 fixture spec →
  handler answers, no agent turn, ledger shows classifier spend; then a
  normal prompt → passes through untouched; then confirm the E2 trigger fires
  once per assistant turn.

## Warnings

- **Engine must be inert by default.** No spec → no model calls, no status
  noise, zero behavior change. Every failure mode (missing service, timeout,
  malformed spec, corrupt file) degrades to unavailable + diagnostic.
- **Never bypass the spend ledger.** All classifier calls go through the
  metered service like `configuredGitInputPlugin`.
- **Respect the pipeline contracts**: processors never touch the live queue,
  host, or driver; background work observes `cancelSignal`; decisions are
  frozen JSON. See `docs/features/input_routing.md`.
- Uncommitted work was in the tree when this was written
  (release_checker / version_status / session-store, touching
  `session_controller.dart` and `tui_coordinator.dart`). Land or stash before
  starting; don't entangle.
- Line anchors drift — grep for the code, don't trust the numbers in this
  document.
- One commit per workstream. Style: `feat(classifier|tui|session): …` — match
  `git log --oneline -15`.
