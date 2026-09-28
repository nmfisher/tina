# Survey — the old sub-agent stack (step 0), and where the port lands

Status: **Approved and executed on this branch** — this survey is the
step-0 record the sub-agents implementation follows (branch `asb/engine2`,
slice "subagents"). The landing points at the end became the
session-details, factory and `tina_subagents` commits.

## Survey report — the old sub-agent stack (step 0)

**`sub_agent_scheduler.dart` (1395 L).** `SubAgentScheduler.spawn()` returns a `SubAgentJob` immediately and runs the job on a detached future; results come back as a `DelegationResult` (content + isError) through a completer; `_extractResult` requires the last message to be assistant text else errors with *"did not finish — ran out of steps or was cancelled"*, then truncates at `resultCharCap` (default 16 000). Depth is enforced at a single chokepoint in `spawn` — a pre-errored job, string *"max nesting depth (N) exceeded"*. The child's transcript **is** persisted (best-effort): the factory mints its own conversation with `ConversationMetaInput.subAgent` + `parentConversationId`. Policy is derived per profile (`_policyForProfile`), with `_neverPreApproved` {bash, exec, fetch, web_search} keeping the parent's decision.

**`agent_quota.dart`.** Process-global; `maxDepth` 0-based (`depth >= maxDepth` rejected, `<= 0` unbounded); `maxLive` = concurrency semaphore, queued waits **unbounded** (excess spawns wait, are never refused). Defaults **3/3** — scheduler ctor `maxConcurrent=3, maxDepth=3`, confirmed in `runtime_config.dart` (`maxSubAgentDepth=3, maxSubAgentConcurrency=3`, `maxSubAgentTokens=2 000 000`, wired via `subAgentBudgetLimit` in `agent_composition.dart:58`).

**`token_budget.dart`** — immutable accumulator, perTurn/perSession/perRequestInput, 90 % soft margin, bytes/4 estimate. **`spend_ledger.dart`** — app-session ceiling + RPM token bucket, latched trip, never reset by /clear. **`pause_gate.dart`** — pause-all gate with cancel-race waiters. **`sub_agent_sink.dart`/`agent_event_bus.dart`** — job events tagged and merged into the parent's stream for the TUI.

**`classifier/judgments/`** — `JudgmentService` iface, `JudgmentCancellation` token, `JudgmentBatchRunner` (concurrency 4, budget reservation: reserve estimate + output allowance, reconcile with measured, halt-on-budget), `JudgmentRequestBudget` (24 k, chunkText), `typesafe_service` (fresh HTTPS-only client per request). The gates pattern = budget reservation + cancellation token.

**What we deliberately will not copy:** detached-future job objects and event-bus merging (our child is a plain awaited session); the unbounded spawn queue (excess spawns get refused, naming concurrency); quota as process-global mutable state (counters live on the session and survive resume); the 16 k result cap; per-job policy derivation (child inherits the parent's mode and can never escalate — mode is passed at factory time); the persistence-best-effort conversation minting (our child's log is just a session with its own id, resumable on its own).

**Decision to flag (brief says "matching the old engine unless the survey says otherwise"):** the old engine's default concurrency is **3**, not 6 — we default to **depth 3, concurrency 3**.

**New-stack landing points (verified):** `Session` has no details mechanism yet (host.dart/session.dart, 41 L) — brief says "the host already persists session details, so make it true": the registry marker row (`tina.session` payload) is the natural place, round-tripped by `Host.start`/`resume`. Factory = `Host.child(...)` style static taking depth, plugins, cwd, mode — assembly only. Plugin/tool in a new `tina_subagents` package; cancellation passthrough via `TurnContext.cancel`; refusal = normal `ToolResult.error` naming the limit.
