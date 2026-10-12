# Daemon sessions — one runtime, multiple TUI clients

Status: **preparatory refactors in progress; daemon not implemented**.
Updated: 2026-10-12, after v0.9.60, session/settings operations, application composition and correlated questions.

Preparation status: phases 0, 1 and 3 are complete. The
[ownership and behavior baseline](session_ownership_baseline.md) records the
original command/settings inventory and lifecycle characterization tests.
All first-party runtime factories are now independent of presentation.
One runtime `PlansPlugin` supplies read-only state to independent `PlansView`
instances.
One runtime `ClassificationPlugin` supplies status and immutable trace snapshots
to independent `ClassificationView` inspectors.
Step-limit policy now uses a plain runtime plugin and the existing generic
Settings panel, with no feature-specific console adapter.
One runtime `McpPlugin` owns configuration, connections, tools and session grants;
independent `McpView` attachments edit settings through `McpManagement`.
Chat, activity, model controls, mode, context, updates, status layout, workspace
panels and approvals now have independent views. Two in-process `SessionView`
attachments share one runtime, including direct host turns and live plugin changes.
The approval and ordinary-question portions of phase 2 and disposable notifications in phase 4
are implemented. Closing a `SessionView` now releases only that view. The panel
workspace also closes borrowed views without cancelling or awaiting shared work;
the embedded application supplies its ownership policy separately, cancelling and
draining accepted host operations before releasing runtime resources.
`Host.connect()` now supplies `SessionConnection` for immutable status, command
metadata/completion, input, steering and cancellation by work ID. Active command
tracking belongs to the host; both TUI paths use the same `SessionView`, with
`SessionPresentation` supplying feature factories and the local settings UI.
`Host.shutdown()` owns asynchronous cancellation/draining and resource cleanup.
Settings/provider editors now use revision-checked operations and sanitized
data through `SettingsManagement`, backed by the application adapter
`ConfigSettingsManagement`. Application composition now lives in `apps/tina_cli`;
`tina_tui` has no feature-plugin dependencies. Ordinary questions now use host-owned
IDs with independent client drafts and cancellation scoped to commands and turns.
Attachment snapshots and bounded in-process delivery are now implemented;
no daemon has been built.

## Assessment

Two in-process session views now share a live runtime with independent
presentation and disposable observations. The engine and host remain the
foundation. The remaining operation/snapshot
contracts still precede a remote client or daemon; wrapping
`SessionAssembly` directly in a socket would bypass those remaining boundaries.

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
| Application assembly | `SessionAssembly` lives in `apps/tina_cli`. Its headless `session.dart` entry point cannot reach a renderer or frontend package. | Application wiring stays above reusable host and frontend packages; scripted turns and resume use the same assembly. |
| TUI lifetime | `SessionView.close` disposes presentation and its connection only. The workspace calls an optional application `onViewClosed` policy. `runTui` in the CLI owns embedded sessions and uses host shutdown to drain accepted work before closing resources. | Borrowed views close independently; frontend quit is local. Settings and ordinary-question dialogs use disposable clients. |
| Notifications | Settings changes, terminal output and plugin lifecycle events support independently disposable listeners; foreground watch lifetime follows runtime log events. | Attachments release only their own listeners. Application commands that open Settings route to the submitting view. |
| Presentation | Every first-party feature view is independent of its runtime plugin. Chat and activity consume immutable session observations; frontend-only IDs have stateless declarations. | Keep one runtime feature instance and a fresh presentation object per attachment. Existing third-party combined contributions retain their compatibility fallback. |
| Live model output | `_ObservedProvider` observes foreground turns through runtime-owned log markers. Chat retains bounded previews independently of attachments. | Direct `Host.send` and turns continuing after detach deliver observations. Background requests remain excluded; late views replay canonical history plus the current preview. |
| Approvals | `ApprovalsPlugin` has request IDs, pending requests, cancellation and single-response tickets. `StreamApprovalChannel` has one subscriber and denies pending requests when it unsubscribes. | The interactive channel is now `AttachmentApprovalChannel`. Each view gets a question facade; the ticket and channel lifetime remain private. Detach retains pending approvals; new headless requests fail closed. |
| Other questions | `SessionTerminal.ask` adapts to `SessionQuestions` in `tina_host`. Each connection receives immutable pending requests and answers by ID. | Detach retains requests. Duplicate, stale and foreign-session responses fail; cancellation, expiry, shutdown and unattended execution settle without an answer. |
| Persistence | Each persistence plugin owns a connection. SQLite uses WAL, a busy timeout and `synchronous=FULL`; session sequence gaps are checked on resume. | Preserve these guarantees. WAL serializes database transactions; it does not enforce one live engine for a particular session. |

Relevant sources:
[`assembly.dart`](../../apps/tina_cli/lib/src/assembly.dart),
[`app.dart`](../../packages/tina_tui/lib/src/app.dart),
[`tui_session.dart`](../../apps/tina_cli/lib/src/tui_session.dart),
[`plugin_catalog.dart`](../../apps/tina_cli/lib/src/plugin_catalog.dart),
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
| `tina_host` | Existing session/plugin lifecycle plus reusable session operations, attachments and observation contracts. No imports of concrete feature plugins. |
| `apps/tina_cli` | Executable application, concrete plugin catalog, configuration and provider wiring, sandbox setup, startup and ownership of embedded sessions. Compose the TUI and headless runner over the same session contracts. |
| Runtime feature packages | Existing policies, settings, stores, processes, feature state and feature-specific operations. |
| `tina_tui` / `*_tui` feature packages | CLI presentation, screens, panels, editors, dialogs and independent feature views for each attachment. |
| Future daemon | Registry, process-level ownership, local transport, authorization and daemon lifecycle, using the same runtime. Deferred. |

Put feature-specific contracts in their owning feature packages. Keep any common
session contracts small. The application directory now exists; a separate
`tina_runtime` package is no longer proposed. Establish the session contracts
before moving composition so the TUI never needs to import the executable
application. Do not add a generic RPC framework or a protocol package during
this refactor. A future second application may justify extracting shared
composition then.

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
through both TUI entry paths. At this initial checkpoint only the plans slice was complete. The later
feature and notification work below now supports two in-process views; the
remaining application/operation phases still precede a daemon.

Initial slice validation: plans runtime tests passed (15); the complete TUI
suite passed (353, with three existing opt-in PTY suites skipped). After the
package extraction and status-line move, the complete `tina_plans_tui` suite
passed (19), the complete chat suite passed (113), affected TUI application,
streaming, workspace and lifecycle tests passed (73), and architecture tests
passed (43). Analysis is clean in all three affected UI/application packages.
The architecture check passes without new exceptions, and the new package has
a CI job selected through the existing dependency graph.

**Classification slice implemented.** The runtime catalog constructs one plain
`ClassificationPlugin` from the terminal-independent `classification` package.
The dedicated `tina_classification_tui` package owns `ClassificationView`, its
panel and tests, with production dependencies only on `classification` and
`tina_console`. Views share a concrete `ClassificationObservation` exposing
status, immutable trace snapshots and existing change streams. Snapshot exchange
records and nested question/answer metadata cannot be mutated by readers; one
snapshot is cached per trace revision and shared between views.

Selection, expansion, detail/raw mode, scrolling, focus, shortcuts, animations
and subscriptions belong to each view. Detaching all inspectors leaves ongoing
inference and category learning with the runtime. Reattaching reads the current
trace without opening another classifier lease or making another model call.
The regular TUI and workspace session views both use the presentation factory
for initial and live plugin loading.

Classification inspection commands use the optional `ConsoleCommandHandler`
capability, dispatched to the submitting attachment. Runtime registration and
its `allowWhileRunning` flag still govern command availability. `/classification`
and `/classification hierarchy` inspect that view; `/classification categories`
and headless commands use the runtime handler. Inspection does not replace a
handler in the shared session command registry. This is a narrow view command
seam; the later session input/approval routing phases remain necessary.

Classification validation: the complete runtime suite passed (242), the new
inspector suite passed (17), and the remaining chat suite passed (99). The TUI
suite passed (356, excluding the compiled-smoke tag and with three existing
opt-in PTY suites skipped), including independent view commands and live reload
through both entry paths. Architecture tests passed (43), analysis is clean in
all five affected packages, and the architecture check has no new exceptions.
The new package has a CI job selected through the existing dependency graph.

**Step-limit slice implemented.** The runtime catalog constructs a plain
`StepLimitPlugin.configured`, reading the effective numeric policy at the start
of each input turn. Its existing setting definition remains installed even when
the plugin is disabled. The application already rendered that definition in the
generic Settings panel; the former `StepLimitConsolePlugin` registered no UI
when scoped settings were supplied. That redundant adapter and chat's dependency
on step-limit policy are removed.

No dedicated step-limit UI package or view factory is needed. Each Settings
panel owns its input, rendering and subscriptions while the runtime retains the
turn's allowance and round counter. Settings edits affect the next input turn;
closing an editor or detaching/replacing a session view does not reset either
value during ongoing work. `StepLimitConfig` still supports the global file
format for standalone callers, and the configured runtime factory accepts that
file path when scoped settings are absent. Application settings retain their
existing session, workspace and global scopes, validation and live enablement.

Step-limit validation: runtime tests passed (12), the remaining chat suite passed
(98), and affected settings, assembly, workspace and lifecycle tests passed (92).
Coverage includes independent scoped editors, rejected numeric input, active
allowance/counter preservation across detach and reattach, next-turn application,
and live unload/reload through both TUI entry paths. Architecture tests passed
(43). Analysis is clean in the three affected packages; the architecture check
passes without new exceptions.

**MCP slice implemented.** The runtime catalog constructs a plain
`McpPlugin.configured`, which owns its config store, connections, discovery,
execution and exact conversation grants. Its `McpManagement` capability exposes
server configuration, immutable status maps, field edits and value-free change
notifications. It provides no tool executor or server-close operation to views.
The original callback-based constructor remains usable without persisted settings.

The dedicated `tina_mcp_tui` package owns `McpView`. Each presentation factory call
creates a new view over the same management capability; each attachment owns
its settings registration and subscription. Status actions write to the invoking
view's chat region. Closing a settings view does not close connections, interrupt
an active call, clear discovered tools or reset exact session grants. Paused
presentation subscriptions cannot delay runtime shutdown.

The settings format, global scope, secret environment/header editors and
next-turn application remain unchanged. Runtime-owned field edits read the latest
saved server before merging a change, preserving other fields edited in another
view. A stale editor cannot recreate a server removed on disk or write after the
runtime closes. Adding/editing settings does not launch a server or request tool
approval; connections still start in `prepareTurn` and calls use the existing
approval policy.

MCP validation: the complete runtime suite passed (19; the optional official
Blender interoperability test remains skipped), the new view suite passed (5),
and affected TUI settings, factory, live-plugin, assembly, workspace and lifecycle
tests passed (119). Tests include two editors merging captured controls,
one shared real subprocess connection, detachment during an active call,
retained session approvals, next-turn disabling and unload/reload while Settings
is open through both TUI entry paths. Architecture tests passed (43); analysis is
clean in all three affected packages. The new package has a dependency-selected
CI job and the architecture check has no new exceptions.

**Remaining feature splits implemented.** Pure `tina_chat`, `tina_activity` and
`tina_session_controls` packages own observation/model state and settings.
`SessionObservationSource` freezes shared log and tool payloads before notifying
views; canonical history remains in the loop. Incomplete previews are bounded
by characters and event count, announce omitted data to late attachments, and
reconcile against committed completion. Persistence still receives batches first.
A detached or throwing observer cannot cancel execution or affect a sibling.

`ModeObservation` exposes policy controls with disposable observation;
`ContextObservation` exposes immutable accepted context and mirror diagnostics.
Mode/context/update/status/panels IDs retain their existing catalog declarations,
commands, settings and dependencies through stateless `PresentationPlugin`s.
Their view objects own overlays, subscriptions, timers, selection and scrolling.
Model pickers have independent filters; a stale picker cannot change a closed
runtime. `/model`, `/context`, `/activity`, `/spawn`, `/close` and `/settings`
open presentation in the invoking attachment. Runtime command registration and
busy-turn policy remain authoritative, with headless fallback diagnostics.

`AttachmentApprovalChannel` owns pending delivery and model suggestions. Each
`ApprovalView` owns its dialog, input capture, regex editor and suggestion
cancellation. Views get immutable requests and a correlated response facade,
never the runtime ticket. The service retains validation and remembered grant
storage. The first accepted answer resolves the question for every view; late
answers cannot apply to a successor. Detaching a view leaves a pending question
available to siblings or reattachment. Session cancellation/expiry/shutdown
still denies it, and requests arriving without a responder fail closed.

The application runner and workspace sessions use independently disposable
terminal/configuration/plugin observers. Workspace mode releases the outer
runner's regular-view observers before creating panel views, so live reload
cannot mount a hidden second copy of the feature. Detaching a `SessionView`
releases only its observers. Its explicit `close` still shuts down the embedded
runtime it owns; a remote lifecycle API remains a later phase.

Architecture coverage now forbids runtime feature construction from importing
presentation packages. CI and dependency-selection policy include the new
runtime and MCP presentation packages without additional baseline exceptions.

Final validation: the TUI suite passed 365 tests with three existing opt-in PTY
suites skipped and the compiled-smoke tag excluded. The engine passed 94 tests,
host 28, chat views 100, approval runtime/views 16/57, context runtime/views
69/10, mode 23, activity views 8 and MCP runtime/views 19/5 (one optional Blender
interoperability test skipped). The new chat/activity/model runtime suites,
step-limit ownership checks and 44 architecture checks also pass. Changed
packages analyze cleanly and formatting/diff checks pass.

Chat views must own their own renderer, markdown state, folds, selection,
scroll-related bookkeeping and console bindings. Runtime features remain single
instances. Read-only projection of their state into multiple views is allowed;
creating another runtime plugin for a second view is not.

Runtime and presentation factories are separate. No first-party combined
wrapper remains; the compatibility fallback is limited to external contributions.

Preserve existing plugin IDs, defaults, dependency declarations, global/
workspace/session overrides and restart-versus-idle application rules. Catalog
validation must recognize presentation-only IDs without constructing TUI code.
Separate a feature's runtime enablement from its client's visibility.

**Completion:** two feature views can attach to the same feature and detach
independently; their state and resources do not overwrite each other. Current
configurations and optional feature selections still load.

### Phase 2 — move interaction ownership into the runtime

**Approvals and ordinary questions implemented.** Approvals retain feature-owned policy and their configured
delivery channels. Ordinary text questions now use `SessionQuestions` in
`tina_host`, exposed through disposable `QuestionClient` instances on session
connections. The compatibility `SessionTerminal` no longer has a FIFO answer
queue. The generic TUI presenter keeps drafts and input ownership local, skips
retired queued dialogs before activating their panel, and releases input on
detach without answering. Another view can answer the same pending ID.

Question lifetimes follow individual host commands and engine turns, including
queued inputs. Scope cancellation rejects late asynchronous re-asks as well as
late responses. Interactive requests default to a five-minute expiry (configurable
by the owner); unattended requests resolve immediately as unavailable. Shutdown
settles pending questions before draining handlers that may await them. These
requests are not persisted across process restart. Tests cover two independent
drafts, out-of-order and stale responses, reconnect, queued focus, expiry, direct
engine cancellation, command isolation, queued-turn isolation and shutdown.

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

**Implemented.** Configuration loading, providers, runtime and view catalogs,
settings adapters and embedded lifecycle now live in `apps/tina_cli`.
`SessionAssembly` and `SessionTerminal` are available through `session.dart`
without transitive terminal imports. The reusable `runApp` accepts a view and
optional application callbacks; `runTui` supplies the CLI's ownership policy.
The resume picker consumes display records instead of persistence objects.
Application integration tests and config verification tooling moved with their
owners. Dependency policy forbids any feature plugin in `tina_tui` and import
checks exclude all terminal packages from the headless composition entry point.
No new runtime package or compatibility dependency back to the CLI was added.

Original scope:

After establishing the reusable session contracts in `tina_host`, move
configuration loading, provider wiring, concrete plugin registration, sandbox
setup and host start/resume into the application under `apps/tina_cli`.
Feature-owned settings remain with their features; shared settings mechanics
remain in `tina_settings`. Move model-catalog data out of presentation packages
where necessary. This phase follows the operation boundary, not a mechanical
file move that makes the TUI depend on the CLI.

Keep process-launch initialization available to the executable bootstrap and
headless runtime without importing terminal rendering. Preserve its trampoline,
pipes, process detachment and cancellation behavior.

Replace `SessionAssembly` call sites with application composition and a TUI receiving
session capabilities. Switch both normal CLI execution and `--prompt`/`--goal`
to the new composition. Keep the current CLI flags, configuration format and
session-store format.

Update architecture policy, dependency checks and CI package selection. Add a
transitive import test excluding `tina_console`, `dart_notcurses` and `*_tui`
from the headless composition entry point. The executable can also import its
TUI entry point, but reusable libraries must never import `apps/tina_cli`.

**Completion:** runtime assembly runs an actual scripted tool turn and resumes a
stored session with no presentation plugins or terminal toolkit reachable.
Interactive behavior uses the same session contracts.

### Phase 4 — introduce attachments and separate lifecycle

Implemented lifecycle subset: `SessionView.close` is idempotent and terminal for
that view, while `detachConsole` remains reusable. Neither operation closes the
host or the terminal's pending questions. Closed views reject new submissions
and ignore stale cancel/input callbacks. `ConsoleWorkspace` accepts an optional
`onViewClosed(view, pendingWork)` callback; without it, panel close, failed
attachment and client exit release presentation only. The workspace no longer
cancels sessions during teardown or waits for borrowed turns. Late completions
cannot repaint disposed panels.

`runTui` in `apps/tina_cli` is explicitly an embedded owner; reusable `runApp`
has no shutdown authority of its own. Its callback cancels and awaits the
submissions it dispatched before closing a spawned session. The initial assembly
remains available for configuration and child creation after its panel closes,
then closes on application exit. Existing CLI startup-failure cleanup remains.
Tests cover closing either shared view during streaming, retained questions and
persistence, borrowed workspace exit, and existing owned panel cleanup.
`Host.shutdown()` now rejects new operations and drains direct `Host.send`
calls, connection-dispatched commands and accepted completion callbacks before
closing plugins and providers.
The assembly also settles its ordinary terminal questions. Synchronous `close`
rejects active host work; callers must await shutdown instead.

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

Implemented input/command subset: `SessionConnection` exposes immutable status,
command metadata and input history, with submission, command completion,
steering and cancellation operations. It exposes no host, loop, concrete plugin,
provider or mutable registry. Each turn (including a steered successor) and each
command invocation gets a new work ID; a stale cancellation cannot affect later
work. Concurrent cancellable invocations of the same legacy command instance
are refused because that instance owns one cancellation callback.

The host owns command tracking across all connections. Both TUI layouts use
the same `SessionView`; frontend quit is local and headless dispatch shares the
host command implementation. The old TUI dispatcher has been removed and its
behavioral tests moved to the host. Disposable status listeners are isolated
from one another and delivered outside synchronous persistence callbacks.

This is an in-process operation boundary, not the complete remote-client
contract below. Retry/deduplication IDs and read-only/control authorization
remain pending. Attachment snapshots use runtime epochs and revisions; see
phase 6 for coalescing and history paging. The configuration adapter
now lives with application composition in the CLI; ordinary questions use the
correlated host service described in phase 2.

Implemented settings/provider subset: `SettingsClient` in `tina_settings`
provides immutable metadata, values, inheritance and application errors, plus
updates by ID/scope/expected revision. Definition validation and storage stay
with `ScopedSettings`. The configuration adapter retains file stale checks,
atomic multi-scope plugin writes, external reload and pending idle/restart status.
The settings and provider panels cannot import config files/backends, plugin
managers, provider implementations or approval stores; an import test enforces
that boundary. Custom feature settings remain feature-owned.

Provider drafts contain only public fields, with separate presence indicators
and explicit keep/replace/clear credential edits. Unknown config fields and
unrelated MCP secrets stay in the owner. Generation saves apply only generation
fields, preserving any unfinished provider/credential draft. Editors close their
own clients, not shared settings. Tests cover concurrent and external edits,
redaction, isolated observers, credential retention/replacement/removal and
existing first-run, provider reload and scoped-plugin behavior.

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

**Implemented in process.** `SessionConnection.attach()` returns an immutable
initial `SessionSnapshot` and a disposable `SessionAttachment` with `next()`.
Capture and registration have no intervening await or client callback. Updates
are complete replacements, not deltas to append. Each attachment keeps one
unread update; overwriting it sets `coalesced`. Clients recover all intervening
committed entries through bounded `history(snapshot:, afterSeq:, limit:)` pages.
Page bounds stay fixed while the session continues. Runtime epochs distinguish
reopened hosts even when their persisted session ID is identical.

Snapshots include status, accepted input IDs/text, all host-managed active work,
active tool calls/progress and bounded output, ordinary questions, installed
plugin IDs and public feature projections. The application's `snapshot_catalog`
adapts existing plugin observations for chat preview, mode, plans, context
revision/budget, classification, model choices, updates, MCP status and approvals.
Full accepted context remains recoverable from its plugin-owned log entries;
snapshots name its revision and position instead of copying every message per
token. Unsupported features have no projection; failed projections are explicitly
listed as unavailable. Snapshot adapters omit provider configuration and MCP
URLs/arguments/environment/headers. Approval observation registers no responder
and preserves third-party delivery authority and unattended denial.

`AgentLoop.publishedSeq` advances only after the entire synchronous dispatch,
including reentrant appends, succeeds. Publication failure freezes that prefix
and sets `historyPublicationFailed`; later writes cannot hide the gap. This
changes observation, not SQLite's transaction or durability policy. Attach during
synchronous publication is rejected. Feature reads are synchronous, read-only
projections; client delivery is deferred and never calls a renderer from the
persistence path.

`SessionView` uses attachment updates for status repaint notifications. Feature
views retain their typed contracts. Chat/activity live delivery has bounded
queues and emits `ObservedReset` followed by a fresh replay after overflow;
adjacent preview tokens are combined during replay to avoid one redraw per token.
Existing preview limits report omissions explicitly. Detaching releases only
the subscription; shutdown delivers final closed state. History and pending
interaction state are not copied to another store. Transport serialization,
cross-process ownership and restart recovery remain later work.

The requirements below describe the boundary implemented by this contract:

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
