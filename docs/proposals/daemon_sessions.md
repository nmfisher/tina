# Daemon sessions — one runtime, multiple TUI clients

Status: **preparatory refactors in progress; daemon not implemented**.
Updated: 2026-10-11, against v0.9.56.

Preparation status: phase 0 is complete. The
[ownership and behavior baseline](session_ownership_baseline.md) records the
command/settings inventory, existing coverage and added lifecycle
characterization tests. Phase 1's plans slice is implemented: one runtime
`PlansPlugin` supplies read-only state to independent `PlansView` instances.
The remaining feature views and later runtime/attachment phases are still pending.

## Assessment

Multiple TUI instances can share a live session without rewriting the engine.
The engine and host provide the right foundation, but the application and
presentation layers do not yet support independent attachments. A socket around
`TuiAssembly` would preserve those problems rather than solve them.

The immediate work is to separate concerns in the existing embedded application.
Do not implement a daemon, socket protocol or background startup in this pass.
Prove the separation with two in-process attachments first.

Keep the plugin structure. Each feature continues to own its policy, state and
settings. A shared session has one instance of each runtime plugin; every attached
TUI has its own presentation objects for those features. Repeated reads by
different plugins remain acceptable. This proposal does not introduce a central
replacement for their stores or change SQLite durability.

## What already works, and what does not

| Area | Verified current behavior | Consequence |
|---|---|---|
| Engine and host | `tina_engine_2` and `tina_host` have no terminal dependency. `Host` owns the loop, provider and mounted plugins. | Retain both; put the application runtime above them. |
| Committed history | `AgentLoop.subscribe` and `subscribeBatches` replay existing entries before delivering new ones. Entries carry `seq`. Batch listeners run before per-entry observers. | Reuse the log for history and preserve persistence before client notification. |
| Application assembly | `TuiAssembly` runs without a screen, but its catalog constructs TUI plugins and supplies concrete tools, providers and settings to them. | A presentation-free runtime requires more than a file move. |
| TUI lifetime | `app.dart` cancels the session on exit; `TuiSession.close` closes the assembly and host. | Detaching a client must become separate from stopping the runtime. |
| Notifications | Assembly settings/watch callbacks, terminal output and plugin-manager callbacks each have one mutable callback slot. | Two clients would replace one another's callbacks. Introduce independently disposable subscriptions. |
| Presentation | Plans now have independent views over a read-only feature observation. `ChatTuiPlugin` still holds one `ConsoleContext`; attaching a new console detaches the previous one. Classification and step-limit adapters still inherit their runtime plugins. | Continue creating presentation objects per attachment; compose them with feature capabilities instead of sharing or duplicating runtime plugins. |
| Live model output | `_ObservedProvider` delivers watch events only while the assembly's `turnObservation` marker is active. `TuiSession.runLine` controls that marker. | Observation must continue regardless of which client initiated a turn or remains attached. |
| Approvals | `ApprovalsPlugin` has request IDs, pending requests, cancellation and single-response tickets. `StreamApprovalChannel` has one subscriber and denies pending requests when it unsubscribes. | Keep the approval service; add a runtime-owned broker instead of subscribing each TUI directly to this channel. |
| Other questions | `TuiTerminal.ask` and `submitAnswer` match questions and answers by FIFO order, without request IDs. | Questions crossing the attachment boundary need correlated IDs and stale-response rejection too. |
| Persistence | Each persistence plugin owns a connection. SQLite uses WAL, a busy timeout and `synchronous=FULL`; session sequence gaps are checked on resume. | Preserve these guarantees. WAL serializes database transactions; it does not enforce one live engine for a particular session. |

Relevant sources:
[`assembly.dart`](../../packages/tina_tui/lib/src/assembly.dart),
[`app.dart`](../../packages/tina_tui/lib/src/app.dart),
[`tui_session.dart`](../../packages/tina_tui/lib/src/tui_session.dart),
[`plugin_catalog.dart`](../../packages/tina_tui/lib/src/plugin_catalog.dart),
[`chat_tui.dart`](../../packages/plugins/tina_chat_tui/lib/src/chat_tui.dart),
[`tina_approvals.dart`](../../packages/plugins/tina_approvals/lib/tina_approvals.dart),
[`loop.dart`](../../packages/tina_engine_2/lib/src/loop.dart),
[`persistence_plugin.dart`](../../packages/plugins/tina_persistence/lib/src/persistence_plugin.dart).

## Ownership and boundaries

```text
TUI A: screen, editor, drafts, scroll, selection, dialogs, feature views
                              |
                         attachment A
                              |
                    session application runtime
                    Host + one AgentLoop
                    runtime feature plugins
                    tools, jobs, providers, approval broker
                    configuration and persistence
                              |
                         attachment B
                              |
TUI B: screen, editor, drafts, scroll, selection, dialogs, feature views
```

An attachment exposes session observations and supported operations. TUI code
does not reach through it to a `Host`, `ToolsPlugin`, provider factory, settings
backend or plugin manager. The embedded CLI owns both a runtime and its
attachment; a future daemon owns the runtime while clients own only attachments.

The runtime owns the session ID, input queue, active turn, tool processes, model
access, permission decisions, remembered grants, plugin graph and persistence.
It also owns transient state needed by a newly attaching client. Presentation
owns terminal input, terminal modes, layout, scrolling, folds, selection and
unfinished input drafts. Presentation preferences may be stored in scoped
configuration without making live UI objects runtime-owned.

Separate client commands from session operations. Opening settings, displaying a
panel and quitting a client are presentation actions. Submitting input, changing
the session's model or permission mode, clearing context, modifying runtime
plugins and cancelling work are runtime operations. Feature plugins still own
those operations; the boundary dispatches to them and enforces session lifecycle.

Settings files can remain the persisted representation. They are not a complete
client API: session overrides, model changes, plugin selection and approval
revocation must be applied through the runtime that owns them. Concurrent edits
need explicit revision/conflict handling rather than silently overwriting another
client's changes. Do not expose provider credentials in client snapshots.

The command-regex feature also needs this separation: model-suggested patterns
are requested from runtime-owned model access. The client edits and confirms the
suggestion; validation and storage of the grant remain runtime-side.

## Multiple clients and lifecycle

All attachments can observe the same committed history and live session state.
Which clients may submit input or answer approvals is a product policy, not a
reason to share editor state. A control lease with read-only observers and
multiple authorized submitting clients can use the same boundary; select the
initial policy before shipping the daemon.

The runtime serializes accepted input. Two clients must not race `Host.send`:
`AgentLoop.runTurn` rejects a second concurrent turn. Give submissions request
IDs and acknowledgements, and deduplicate retries for the lifetime of the
runtime. Cancels target a particular turn or job, so a delayed cancellation does
not cancel its successor. Settings and plugin changes retain their existing
idle requirements or report that they are deferred.

Detaching releases only that attachment's subscriptions and presentation
resources. It does not cancel a turn, close input for other clients, unload a
runtime plugin or close persistence. An explicit runtime shutdown does those
things. Embedded CLI exit can continue to shut down the runtime it owns; a
future attached client's `/quit` only detaches.

The daemon eventually needs a registry keyed by store identity and session ID:
attach to an existing runtime instead of resuming the same log into another
engine. Exclusive ownership must also cover competing daemon or embedded
processes, using a respected process-level session lease. Multiple sessions and
their separate persistence-plugin connections can still share a SQLite file.
Do not infer session ownership from WAL or `busy_timeout`.

## Attach, reconnect and slow clients

An attachment starts with a consistent snapshot and an event cursor, then
receives subsequent events without a gap. The snapshot includes committed
history, running/idle state, accepted queued inputs, current model and mode,
active tools and pending questions. Attaching mid-response also needs the
partial assistant output; that text is not yet a committed message in the log.

Keep durable log sequence numbers separate from transient event ordering. A
log `seq` alone cannot recover model deltas, tool progress or questions. After
a gap in transient events, send a fresh snapshot rather than pretending the
committed log is enough. Capturing a snapshot and subscribing must have a
defined ordering boundary.

Client delivery must not perform socket I/O inside the engine's synchronous
listener callbacks. Persistence failures must continue to stop the session;
a disconnected client or failed renderer must not poison the shared loop.
Use bounded delivery queues. Coalesce replaceable progress updates or require
resynchronization when a client falls behind; do not silently lose committed
history or grow memory without limit.

Reconnect to a live runtime and recovery after a daemon crash are different.
The existing store restores committed history, not a running process, a partial
model stream or an in-memory waiting question. Restart recovery and durable
request deduplication are later work. Do not promise exactly-once external tool
effects or automatically rerun interrupted commands.

## Approvals and questions

The broker belongs to the runtime and keeps receiving tickets even with no
attached TUI. It exposes pending requests in attachment snapshots and publishes
their resolution to every client. Only authorized clients can answer, and the
first valid answer for an active request wins. Late or duplicate answers are
rejected; answering never executes an operation directly in a client.

A temporary disconnect should not be treated as a human denial. Proposed
interactive behavior: leave the request pending, with no operation authorized,
until an authorized client answers, the turn is cancelled, an explicit deadline
expires or the runtime shuts down. Keep unattended/headless deny policy explicit.
Waiting remains fail-closed: a missing answer never grants access. This changes
the older recommendation to deny immediately whenever no client is attached.
Record why a request resolved instead of attributing automatic denials to a user.

Use correlated IDs for ordinary questions and confirmations as well as
permission requests. A FIFO answer buffer cannot safely route responses from
multiple clients. Durable waiting questions across daemon restart are out of
scope for the initial refactor.

The older [`remote_answerable_approvals.md`](remote_answerable_approvals.md)
contains useful broader requirements, but its legacy-engine source references
and claims about current implementation need revalidation. The facts above are
checked against engine2 and the current approval plugins.

## Detailed preparatory implementation plan

Names below are proposed. The package split and ownership rules matter more than
the spelling of the new classes. Every phase should land with interactive,
headless and resume behavior working; large feature conversions can be separate
commits within a phase.

### Proposed package boundaries

| Owner | Responsibilities after the refactor |
|---|---|
| `tina_core` / `tina_engine_2` | Existing value types, one loop, log writes, cancellation and tool execution phases. No client or transport logic. |
| `tina_host` | Existing session/plugin lifecycle and terminal-independent session observation contracts. No imports of concrete feature plugins. |
| New `packages/tina_runtime` | Application composition, runtime plugin catalog, configuration services, session operations, attachments and observation delivery. No terminal toolkit or TUI plugin dependency. |
| Runtime feature packages | Existing policies, settings, stores, processes, feature state and feature-specific operations. |
| `tina_tui` / `*_tui` feature packages | CLI presentation, screens, panels, editors, dialogs and independent feature views for each attachment. |
| Future daemon | Registry, process-level ownership, local transport, authorization and daemon lifecycle, using the same runtime. Deferred. |

Put feature-specific contracts in their owning feature packages. Keep any common
session contracts small. Do not add a generic RPC framework or a protocol package
during this refactor.

### Phase 0 — pin behavior and ownership

Build an operation inventory covering both `app.dart` and `SessionView`, including
the panel workspace. Classify each command and setting as client-local,
session-owned or application/configuration-owned.

Record the behaviors that must survive: headless deny policy, sandbox and
credential masking, scoped grants, regex editing and revocation, input steering,
live plugin changes, model reload, resume, process cancellation and terminal
restoration. Reuse existing coverage; add characterization tests only for
uncovered behavior that the refactor will touch.

Input steering deserves explicit coverage: the existing `offerInput` can close an
in-flight model call and run accepted input after pairing tool calls. This is not
a request to replace that behavior with a different queue.

**Completion:** a concrete ownership/command matrix and baseline coverage for
interactive, headless and panel paths, with no behavior changes.

### Phase 1 — extract independent feature views

**Plans slice implemented.** `tina_plans` owns a concrete `PlanObservation`
with the current immutable snapshot and the existing broadcast change stream.
The dedicated `tina_plans_tui` package owns `PlansView`, `PlanOverlay`, the
progress/approval status line and their tests. Chat no longer decodes plan
entries or renders plan status. The plans UI depends only on `tina_plans` and
`tina_console` in production; it has no chat dependency. Its views receive the
observation, with no store mutation or disposal capability. Each view owns
its selection, expansion, scrolling,
focus, shortcuts, animation and subscription lifetime.

Runtime construction in `plugin_catalog.dart` now creates a plain `PlansPlugin`.
The separate `console_catalog.dart` creates a fresh plans view for each
attachment; both `runApp` and the workspace's `SessionView` use it. Plans retain
their existing ID, dependencies, commands, approval flow and live settings.
Existing combined contributions remain compatible while their own factories
migrate. No plans compatibility wrapper remains.

Coverage includes two views sharing updates with independent presentation state,
detaching either view while the other continues, reattachment from the latest
snapshot, defensive snapshot immutability, and initial/live load/unload/reload
through both TUI entry paths. This completes the plans slice only; the shared
callback slots and interaction lifetimes still prevent general simultaneous
session attachments until the later phases.

Initial slice validation: plans runtime tests passed (15); the complete TUI
suite passed (353, with three existing opt-in PTY suites skipped). After the
package extraction and status-line move, the complete `tina_plans_tui` suite
passed (19), the complete chat suite passed (113), affected TUI application,
streaming, workspace and lifecycle tests passed (73), and architecture tests
passed (43). Analysis is clean in all three affected UI/application packages.
The architecture check passes without new exceptions, and the new package has
a CI job selected through the existing dependency graph.

Convert presentation adapters that inherit runtime plugins into separate views
that receive the feature's state/operation capability. Start with plans,
classification, step limits and MCP; then separate mode, context, activity,
chat, updates, session controls and workspace panels.

Chat views must own their own renderer, markdown state, folds, selection,
scroll-related bookkeeping and console bindings. Runtime features remain single
instances. Read-only projection of their state into multiple views is allowed;
creating another runtime plugin for a second view is not.

Split factory registration into runtime factories and presentation factories.
Keep a compatibility composition wrapper where needed while the current
assembly still constructs both. Remove that wrapper once callers migrate.

Preserve existing plugin IDs, defaults, dependency declarations, global/
workspace/session overrides and restart-versus-idle application rules. Catalog
validation must recognize presentation-only IDs without constructing TUI code.
Separate a feature's runtime enablement from its client's visibility.

**Completion:** two feature views can attach to the same feature and detach
independently; their state and resources do not overwrite each other. Current
configurations and optional feature selections still load.

### Phase 2 — move interaction ownership into the runtime

Put an approval broker at the runtime boundary. It owns delivery lifetime and
publishes request/resolution observations; `ApprovalsPlugin` continues to own
validation, cancellation and the ticket's authority.

A TUI gets request data and submits an answer by request ID. It does not receive
a runtime `ApprovalTicket` or provider object. Validate authorization, scope,
pattern and request activity before submitting an answer to the ticket. Invalid
or stale client answers must not consume another client's active request.
The first valid answer resolves it and closes every view of that request.

Preserve configured approval delivery choices. Existing TUI delivery IDs can map
to a runtime attachment channel plus a client view. Existing third-party channels
retain their delivery authority and APIs; the broker must not silently turn an
externally delivered request into an unrestricted TUI approval.

Move command-pattern suggestion requests behind a runtime operation. The
runtime leases the model provider; each client retains its own draft, fallback,
edit-preservation and confirmation flow. Losing a dialog cancels its suggestion
work, not the entire session or another client's dialog.

Add a correlated question service for remaining `Terminal.ask` consumers.
A compatibility `Terminal` adapter can translate existing calls into identified
questions while callers migrate. Runtime notices also get explicit routing:
session activity is shared; the result of a client-local command stays local.

Keep interaction policy explicit: unattended/headless denies; an interactive
runtime can wait for an answer even if all its clients temporarily detach.
Cancellation, configured expiry and shutdown resolve pending requests without
authorizing an operation.

**Completion:** approval and question tests cover duplicate/stale answers,
disconnect, cancellation, all three remembered-grant scopes, regex suggestions
and a configured third-party channel.

### Phase 3 — extract a presentation-free application assembly

Create `tina_runtime` and move configuration loading, provider wiring, runtime
plugin registration, scoped settings, sandbox setup and host start/resume into
`RuntimeAssembly`. Move model-catalog data out of the chat presentation package.

Keep process-launch initialization available to the executable bootstrap and
headless runtime without importing terminal rendering. Preserve its trampoline,
pipes, process detachment and cancellation behavior.

Reduce `TuiAssembly` to a temporary compatibility facade over the runtime plus
presentation construction. Switch both normal CLI execution and
`--prompt`/`--goal` to the new composition. Keep the current CLI flags, configuration
format and session-store format.

Register the package in architecture policy, dependency checks and CI package
selection. Add a transitive import test excluding `tina_console`,
`dart_notcurses` and `*_tui` from the runtime. Do not exempt the new package from
the existing dependency rules to make the move pass.

**Completion:** runtime assembly runs an actual scripted tool turn and resumes a
stored session with no presentation plugins or terminal toolkit reachable.
Interactive behavior still passes through the compatibility facade.

### Phase 4 — introduce attachments and separate lifecycle

Add a concrete in-process `SessionAttachment`. Its surface contains immutable
observations, supported operations and disposable subscriptions. It does not
expose `Host`, `AgentLoop`, tools, provider factories, plugin managers or writable
settings backends.

Replace presentation callback slots with subscriptions. Observe the session's
main model calls for the lifetime of the turn, independent of a TUI's
`turnObservation` flag. Attribute events to session, turn and model-call IDs;
auxiliary classifier/suggestion calls and child sessions must not leak into the
parent transcript.

Make `detach` idempotent and limited to an attachment's resources. Make runtime
`shutdown` explicit and asynchronous: reject new operations, cancel owned work,
settle active turns/requests, then close plugins, providers and persistence.
Do not close the store underneath a still-running turn.

The embedded CLI retains an owner that shuts down its runtime on exit. A client
that does not own the runtime only detaches. Apply this to `app.dart`,
`SessionView` and the panel workspace, including panel-close and exception paths.

**Completion:** detaching either of two attachments does not cancel a turn,
resolve another attachment's questions, unload a plugin or close the store.
Embedded exit still restores terminal state and closes its owned runtime.

### Phase 5 — route input, commands and settings through operations

Move dispatch authority and command/job lifetime out of `TuiSession`. Return
operation results or job IDs rather than exposing executable `Command` callbacks
to clients. Each runtime feature still implements its own commands.

The boundary accepts input with a client request ID and returns its accepted
input/turn ID and status. Repeated IDs with the same payload return the original
result; reusing an ID with different input is rejected. Retain the engine's
existing queue and steering behavior instead of inventing a second authoritative
queue. Handle submissions at idle/turn-transition boundaries explicitly.

An acceptance acknowledgement means accepted in memory. It is not a promise of
durability until the corresponding input entry commits. Publish cancellation or
rejection if accepted queued work is dropped, and keep the deduplication window
bounded with an explicit retry-expiry contract.

Cancel operations name a turn or job. A stale cancel cannot stop a successor.
Read-only attachments can observe but cannot submit input, change session state
or answer questions. The runtime assigns permissions; clients cannot elevate
themselves. Whether a future daemon permits several controlling clients or uses
a control lease remains a shipping policy.

Split local commands such as opening settings, panels and quitting the client
from runtime operations such as changing model/mode, clearing context and
running user-entered shell jobs. Preserve the distinction between explicit user
shell execution and model-requested tools and their approval/sandbox policy.

Expose setting definitions, values, inheritance, application status and
validation errors as data. Apply mutations by setting ID, scope and expected
revision through the owning runtime/feature. Reject stale edits, refresh the
client and retain the existing atomic scoped-write behavior. Preserve pending
idle/restart changes and external-file hot reload.

Provider and MCP secrets must not appear in generic snapshots. Secret editors
need explicit keep/replace/clear behavior. Remembered approvals are listed and
revoked through their feature's operation, including regex rules.

Migrate `app.dart`, `SessionView`, settings/providers panels, session selection,
command completion and dialogs. Remove compatibility accessors as callers move.

**Completion:** TUI code has no direct path to runtime implementation objects.
Simultaneous input, stale cancels, conflicting edits, live plugin changes and
approval revocation behave consistently in both attachments.

### Phase 6 — implement complete attach snapshots and bounded delivery

Define a snapshot containing session identity and runtime epoch, committed log
position, model/status, accepted inputs, active jobs/tools, pending interactions,
feature state and current partial assistant/thinking output where supported.

Create the snapshot and its event subscription at one ordering boundary. The
client receives state through cursor N followed by events after N. Use a
transient event cursor separate from persisted log `seq`; resume creates a new
runtime epoch. Completed model output replaces its preview without duplicating
the committed message.

Keep durable history in the existing log and store. Feature projections and
transient state are derived views, not another durable transcript or central
replacement for feature stores. History may be paged separately if needed;
avoid forcing an unbounded full-history copy on every attachment.

Client delivery uses bounded queues and happens outside persistence-critical
synchronous callbacks. A failed renderer or disconnected/slow consumer is
isolated. Coalesce replaceable progress, or require a fresh snapshot when its
cursor is no longer recoverable. Never silently drop committed history.

**Completion:** attach during streaming/tool execution/approval wait has no
missing or duplicated state. Slow/failed consumers cannot fail the shared loop,
block persistence or grow delivery buffers indefinitely.

### Phase 7 — prove the boundaries and remove transitional wiring

Use a deterministic provider and controllable tool runner to test a live runtime
with two independent attachments and console contexts. Exercise both top-level
and panel views: attach before/during a turn, simultaneous input, dialog edits,
approval resolution, settings changes, feature toggling, detach and reattach.

Test the less visible paths: compaction/clear, model switch and hot reload,
subagents/child sessions, goals, MCP, explicit user shell jobs, failed provider
calls, persistence failure and orderly shutdown. Assertions should verify shared
behavior and independent presentation, not mirror private implementation.

Remove the old combined catalog, inherited UI/runtime adapters and lifecycle
fallbacks after all callers migrate. Keep temporary import re-exports only when
a public compatibility requirement calls for them.

**Completion:** the required verification below passes, architecture checks
enforce the new dependency graph and normal CLI, headless, resume and native
smoke suites remain green. No daemon or cross-process sharing is needed to prove
the result.

## Verification and delivery

Use the repository Dart SDK specified in `AGENTS.local.md`. At each phase run
the changed packages and their dependent test closure, plus architecture/config
compatibility tests when a registration or import changes. Run analysis and
format checks for source edits.

Run the applicable compiled CLI and native TUI smoke suites when composition,
process launching, input ownership or teardown changes. Keep live provider tests
opt-in; deterministic tests should cover the refactor without an API token.
Run the complete impacted integration suite at the final boundary. Do not
rerun unchanged checks solely because another documentation commit lands.

Each phase or feature conversion should be a reviewable commit/PR with its
validation stated. The largest work is converting presentation ownership and
settings/provider editors; the package extraction itself is comparatively
mechanical once those prerequisites land.

## Daemon work deferred until the preparation passes

Later work adds the live-session registry, cross-process session lease, local
socket authorization, transport negotiation, reconnect, daemon startup/shutdown,
idle-session policy and update coordination. Multiple sessions and child
sessions can keep separate persistence-plugin connections to the same store;
`synchronous=FULL`, atomic batches and persistence-failure propagation stay.

A process lease must be respected by both daemon and embedded writers.
Database WAL is not that lease. Recovery after daemon failure, durable pending
questions, durable request deduplication and remote clients are separate
requirements; reconnecting to a still-live runtime does not provide them.

## Required verification

- A runtime can start and run headless with no terminal renderer or TUI plugins.
- Two attachments receive the same history and subsequent entries, with
  independent drafts, scroll, selections and dialogs.
- Attaching during a streamed response shows its current partial output and
  pending tools/questions, then receives updates without gaps or duplicates.
- Closing one attachment leaves the other and the active turn running; closing
  the runtime resolves pending requests and releases jobs, providers and stores.
- Simultaneous submissions are acknowledged and serialized; retries do not add
  another input. A stale cancel cannot affect the next turn or another job.
- An approval answered in either authorized client resolves once, closes in
  both, rejects later answers and persists a remembered grant only once.
- Disconnecting all clients never authorizes an operation. Reattachment can
  recover a pending question under the proposed interactive waiting policy.
- Feature enable/disable and session settings updates reach both attachments
  without duplicating runtime plugins or accepting stale conflicting edits.
- A failed or slow client cannot block persistence, fail the shared loop or
  cause unbounded buffering; resynchronization restores a consistent view.
- Existing persistence tests still enforce `synchronous=FULL`, atomic batches,
  sequence integrity and propagation of persistence failures.
- Before daemon shipping, competing processes cannot own the same session;
  separate sessions and child sessions can still share the store safely.
