# A04 — Separate turn execution, background jobs and frontend input

Status: proposed. Coordinates with A03 and A05.

## Problem

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
