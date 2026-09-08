# A04 — Separate turn execution, background jobs and frontend input

Status: implemented and validated (2026-09-08). Builds on A03 and A05.

## Implementation

`application/turn_executor.dart` is the sole admission and queue-drain owner.
`submit(id, prompt)` returns started, queued or rejected; `cancel`,
`interruptTools`, `whenIdle`, `close` and `shutdown` expose execution without an
input loop. An explicit slot remains held through provider cancellation,
recorder writes and usage persistence. `Conversation.isRunning` now remains true
until the executor clears the marker, including cancellation acknowledgement.
Closing marks a conversation unavailable, cancels its work and prevents another
queued turn. `MessageQueue` itself and one-message-at-a-time draining are unchanged.

The compatibility `SessionController` now handles the read/dispatch loop, optional
frontend callbacks and session navigation. It delegates turns and workflow-result
injection to the executor, and jobs to the application supervisor. It no longer
implements `CommandContext`. `frontend/session_input_state.dart` owns draft buffers
and Escape arming; the facade retains gesture mapping and editor callbacks during
migration. This is intentionally still a frontend facade, not a new application
service locator.

`application/background_job_supervisor.dart` owns identity, kind, conversation ID,
idempotent cancellation and a completion future. Admission remains one job per
kind across the application: one index job and one environment job may coexist,
but another conversation cannot start a second job of the same kind. Completion
settles on success or failure, with failures observable on the handle; guards
clear in `finally`. `project_background_jobs.dart` binds A05 services, captured
conversation output and completion/usage notices. First-load environment setup
now also uses the environment guard, while retaining its selected model, scout
panels and attention-queue permission asker in the TUI adapter.

`session_commands/command_capabilities.dart` defines separate dispatch, history,
sessions, permissions, indexing, frontend, workflow, usage and update interfaces.
`command_families.dart` holds handlers typed to those smaller interfaces. The
existing registry, aliases, help order, completion order and headless fallback
messages are retained. `SessionCommandHandlers.withCapabilities` accepts explicit
capabilities; its old constructor and the legacy `CommandContext` aggregate remain
compatibility adapters. `ControllerCommandAdapter` bridges the facade. Unused
exit-dialog and environment-service members were removed from the aggregate.
`/index` captures its conversation before asynchronous confirmation; `CmdRun`
enters executor admission for the conversation captured at dispatch.

## Turn and persistence ordering

The extraction preserves these steps:

1. Admit synchronously, establish fresh cancel/tool-interrupt signals, and hold
   an activity identity. Echo the user's prompt and separators.
2. Auto-compact if configured, persisting a successful compacted history through
   recorder replacement. Capture the pre-turn history length afterwards.
3. Append the user message to persistence before invoking `Agent.run` so the
   prompt survives a process exit during the response. The agent appends the
   corresponding in-memory user message.
4. Run the agent, including tool/assistant history updates. If it aborts normally,
   append the existing synthetic abort-reason message.
5. Explicit operator cancellation restores the pre-turn history and replaces the
   recorder transcript. Otherwise append the new assistant/tool messages,
   skipping the already-persisted user message. Recorder failures are reported
   best-effort and never leave admission busy forever.
6. Settle activity and best-effort usage persistence for the owning conversation's
   session, then drain the next queued prompt. Admission stays held until the
   entire drain is idle. Focus changes do not redirect output or usage writes.

Tool interruption still completes a separate signal, leaving cancellation unset;
the engine finishes its tool-batch protocol and the next queued prompt follows.
`Agent.compact` now accepts an optional cancellation signal and awaits subscription
cancellation before returning without altering history. This closes a shutdown
hole where a pre-turn compaction could otherwise hold the executor indefinitely.

Workflow completion uses the same executor submission method and launching ID.
Synthetic wording and 4,000-character output truncation are unchanged. Cancelled
results are suppressed; closed/missing conversations reject late submissions.

## Lifecycle and shutdown

The engine agent imports only the small `RunLifecycleSink`/`RunActivity` contract,
not `HostInterface`. A unique identity starts and completes exactly once around
each run. `HostLifecycleAdapter` tracks all active identities; one completed run
cannot clear another's activity. Observer exceptions are cosmetic and cannot skip
runtime cleanup. The turn executor, environment ceremony, workflow supervisor and
panelized sub-agent scheduler hold outer activity identities where their work
extends beyond an individual agent call. TUI idle resynchronization respects those
active identities.

`WorkflowSupervisor` now provides `done` and `shutdown`, rejects late launches,
waits for cancelled work, and settles completion even when reporting/listeners
throw. On shutdown it suppresses completion-turn injection. Controller shutdown
starts cancellation of turns, jobs and workflows, awaits them, then flushes usage;
TUI teardown calls it before disposing scheduler/panels/providers. Session removal
marks conversations closed immediately but defers provider/host disposal until
turn completion. Deferred close failures are retained for `closeAll` to observe.

**Exit differs from explicit Escape cancellation:** quitting mid-response retains
the user prompt already flushed to disk for resume. Shutdown stops queued work
instead of launching it after exit; explicit cancellation during an open session
continues to preserve and drain the backlog. Tests now assert cancellation stays
busy until cleanup, and that shutdown clears remaining queued work.

## Validation and follow-on work

379 distinct targeted root tests and all 892 engine tests pass. Root and engine
analysis are clean; see [HANDOFF.md](HANDOFF.md) for combined and focused commands.
New concurrency tests use controlled streams/completers for cancellation during
rollback, queue admission, compaction cancellation, shutdown acknowledgement,
late workflow results, job guards, host disposal and observer failures. Existing
command goldens, workflow tests, TUI gestures/drafts, A03 operations and A05 service
integration tests remain covered.

A07 should now classify these modules automatically and replace the growing
explicit boundary-test list with its graph policy. A06 can then extract the
established application layer. The legacy command adapter and frontend facade are
explicit compatibility surfaces, not reasons to move terminal dependencies into
the new application package.

## Original problem

[`SessionController`](../../../lib/session_controller.dart) owns input dispatch,
queued turns, cancellation, compaction, persistence, background summary/environment
jobs, input drafts and many mutable overlay callbacks.
[`CommandContext`](../../../lib/session_commands/command_context.dart) exposes
much of that surface to every command. The command registry already exists;
the next step is narrower handlers, not another registry implementation.

[`Agent.run`](../../../packages/tina_engine/lib/src/agent/agent.dart) also tests
whether its sink is a `HostInterface` to set activity. Engine execution therefore
knows a larger presentation contract despite accepting an `AgentSink`.

## Target components

| Component | Owns | Must not own |
| --- | --- | --- |
| `TurnExecutor` | Per-conversation admission, queue draining, compaction, agent run and recorder ordering | Keyboard gestures, overlays or focus |
| `BackgroundJobSupervisor` | Job admission, cancellation handles, completion and shutdown | Summary staleness rules or panel allocation |
| Command handlers | Parse command arguments and invoke relevant operations | Mutable controller-wide service locator |
| Frontend input controller | Read loop, drafts, focus synchronization, double-Escape gesture | Provider creation or persistence policy |
| Host lifecycle adapter | Convert lifecycle state to activity/busy presentation | Agent execution decisions |

Keep `SessionController` as a compatibility facade during migration. Its final
role may be a small input/dispatch adapter; it should not implement every service
interface to preserve its old constructor shape.

## Turn execution contract

Provide operations equivalent to `submit(conversationId, prompt)`,
`cancel(conversationId)`, `interruptTools(conversationId)` and `whenIdle(id)`.
Submission reports whether work started, queued or was rejected because the
conversation is closing. Preserve existing queue semantics in `MessageQueue`;
do not introduce a different batching strategy.

The executor owns an explicit per-conversation state with idle, running,
cancelling and closed states. Cancellation being requested is distinct from the
underlying asynchronous run having finished. Exactly one turn may execute per
conversation, including while cancellation is being acknowledged.

For each turn, preserve the current order of user-history recording, compaction,
provider invocation, assistant/tool history updates and usage persistence.
Document that order from `_runTurn` in the implementation PR before moving it.
Persisted message ordering must remain compatible with replay and resume.

Tool interruption remains distinct from cancellation: an in-flight tool batch
finishes according to the engine contract, the queued operator input becomes
eligible next, and no fake cancellation notice is introduced.

### Workflow completion

Route workflow-result injection through the same submission operation, targeting
the launching conversation ID. Preserve existing synthetic prompt wording and
truncation. Cancelled workflow results remain suppressed; results for closed
conversations remain ignored. Queue them behind an active turn as today.

## Background jobs

Use a small job handle with identity, kind, owning conversation ID, completion
future and idempotent cancellation. The supervisor prevents duplicate work using
the same scope as current guards; do not silently broaden concurrency from one
application job to one job per conversation during extraction.

Summary/environment execution receives factories from A05. Supervisor state is
cleared in `finally` for success, cancellation and exceptions. Capture the owning
conversation before awaiting. Switching focus must not reroute output or cancel
the wrong job. Preserve current Escape cancellation priority with frontend tests.

Shutdown rejects new work, cancels jobs/turns, awaits completion and then releases
owned resources. Late workflow completions cannot reopen a closing conversation.

## Commands and frontend capabilities

Keep existing command names, aliases, metadata, help order and completion order.
Change registration so a handler closes over only its dependencies, for example
session operations for `/session`, a summary service for `/index`, and a frontend
action for `/settings`. Group related capabilities where useful; avoid one giant
replacement interface called `ApplicationContext`.

UI-only commands receive optional frontend capabilities at registration. Preserve
their current headless fallback messages rather than removing commands from help
or changing unsupported-action behavior. `CmdRun` continues to enter the ordinary
turn path. Command parsing remains independent of terminal rendering.

## Lifecycle signals

Add the smallest engine-level lifecycle contract needed by the host. Prefer an
existing event/sink seam if it can express run start and terminal completion
without introducing a second source of truth. Include run identity where nested
or concurrent runs share a host. Do not make `Agent` import `HostInterface`.

Each started run emits one completion signal on success, error or cancellation.
The host derives activity from active work identities, so one completed run does
not clear another run's busy indication. Workflow/background operations may
retain activity across extra work around an agent call; their lifecycle ownership
must be explicit. Cosmetic listener failures must not skip runtime cleanup.

This is a targeted signal with existing consumers, not the general extension
lifecycle bus deferred in the older plugin-seams proposal.

## Migration

1. Extract `TurnExecutor` behind existing controller methods and preserve tests.
2. Add direct executor tests with controllable provider streams and completions.
3. Extract background job state and A05 runners; keep frontend cancellation
   gesture mapping in the controller temporarily.
4. Migrate command families to narrow injected dependencies incrementally.
5. Move draft buffers and Escape arming to frontend input ownership.
6. Replace engine host checks with lifecycle signals and a host adapter.
7. Remove obsolete controller fields and broad `CommandContext` members.

## Acceptance criteria

- Turn sequencing, queued input, cancellation acknowledgement, tool interruption
  and workflow completion are testable without an input loop.
- Controlled completers, not arbitrary sleeps, drive concurrency tests.
- Recorder failures and provider failures leave no stuck running/busy state.
- Closing a conversation during a run prevents subsequent queued execution.
- Switching focus does not change the owner of a turn or background job.
- Lifecycle tests cover concurrent work sharing a host and observer exceptions.
- The engine agent imports no host presentation interface.
- Existing session, command, workflow and host busy-cue tests remain passing;
  terminal tests retain responsibility for gestures, drafts and visual state.
