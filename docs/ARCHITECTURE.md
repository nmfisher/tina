# Architecture

tina is an agent runtime. An agent is a model session that acts through
tools: it streams from a provider, requests tool calls, passes each one
through a permission gate, and repeats until the model is done. tina
implements that loop once, plus the machinery every agent needs — context
building, sandboxed execution, permission checks, session persistence — and
a plugin system for everything that varies.

Nothing in the core assumes a terminal or a coding project; those are
contributions. The shipped binary mounts a terminal front end and a
headless runner (`--prompt`, `--goal`) over one assembly. This document
explains the core first, then says what is **baked in** and what is
**mounted as a plugin**.

## The main loop

A turn is one cycle:

1. **Build the context.** The system prompt is assembled fresh.
2. **Stream from the model.** Text deltas and tool-call requests arrive as
   events.
3. **Run tool calls through the permission gate.** Allowed calls execute
   inside the sandbox (a working set of writable paths). Denied calls
   return an explanation to the model. Everything else asks — an approval
   card in the TUI, the policy itself headless.
4. **Append results to the log and repeat**, until the model stops calling
   tools.

**The log.** The loop (`AgentLoop` in `tina_engine_2`) owns an append-only
log of session entries and is its only writer. Every turn appends its
entries — turn started, the input as typed, one per plugin rewrite, one
per message, turn ended with stop reason and usage — and publishes each
entry to listeners as either `appended` (it just landed) or `replay` (a
listener subscribed and is receiving the log that already exists). There
is no transcript beside the log: the messages a request carries are
derived per request via `deriveSession` (`tina_core`).

**Where input comes from.** Usually a person: the TUI hands a line to the
host, which runs it as a turn (`Host.send`). But a user is optional.
Headless, the input is the `--prompt` argument or stdin. A `--goal` run
synthesizes its own input: after each turn a judge reads the transcript
against the goal and prepends a correction nudge until the goal is met.
The main place a person is consulted mid-run is an approval ask —
headless, even that is answered by policy.

The cycle is bounded: step caps, spend limits, and context management
(step limits and compaction are plugin contributions — `tina_step_limit`,
`tina_compaction`). An interrupt injects a cancel signal into
running tools and the model stream; the log is persisted as it grows, so
an interrupted turn still ends cleanly and resumes.

This loop is written **once**. The TUI, headless runs, sub-agents and
workflow nodes all run it.

## The package stack

```
apps/tina_cli               application (package tina): CLI, headless runner, process startup
packages/tina_tui           reusable terminal front end and injectable session assembly
tool/repository            repository architecture checks and CI helpers
packages/tina_host          session lifecycle: Host, HostConfig, Commands
packages/tina_engine_2      the agent loop and plugin interface
packages/tina_core          value types: messages, log entries, Terminal,
                            provider and command contracts
packages/tina_llm           model providers and wires
packages/tina_console       terminal toolkit (renderers, editor, notcurses)
packages/dart_notcurses     vendored native binding
packages/tina_sqlite        sqlite wrapper (WAL, busy_timeout)
packages/plugins/*          feature plugins, mounted by the assembly
packages/libraries/*        domain-neutral helpers (tina_settings, …)
classification, file_tree,  small pure support packages
tina_index, attractor
```

Dependency direction, top down only:

- **tina_core** — shared contracts only; standard-library Dart. Everything
  below it depends on it, it depends on nothing.
- **tina_engine_2** — `AgentLoop`: turn phases, the append-only log and
  its listeners, the `AgentPlugin` interface, tool execution policy.
  Terminal-free.
- **tina_host** — `Host` owns one `AgentLoop` plus its mounted plugins and
  published commands; `Host.start`/`Host.resume` validate declarations
  before opening resources and roll back on failure. `Host.connect()` supplies
  a disposable `SessionConnection`: immutable status and command metadata,
  completion, input submission/steering and cancellation by work ID. Command
  execution and active-work tracking are shared by all connections. Owner-only
  `shutdown()` rejects new work, cancels and drains accepted work, then closes
  plugins and the provider. Terminal-free.
- **tina_llm** — `LlmProvider` implementations and the provider
  descriptors the config system reads.
- **tina** (`apps/tina_cli`) — the executable application. `cli.dart` routes
  interactive TUI, headless `--prompt`/`--goal`, configuration, model listing,
  resume and session import. It owns the release version, shell completion,
  process launcher and terminal restart. Libraries and plugins cannot depend
  on it.
- **tina_tui** — the reusable front end and session assembly today:
  - `assembly.dart` (`TuiAssembly`) is the composition root: loads
    config, builds the scoped settings stack, the plugin registry, the
    provider policy, the `ToolsPlugin` sandbox, and starts or resumes the
    `Host`. Everything it needs is injectable (`Terminal`, writer,
    provider factory), so a test — or a daemon — runs the whole app with
    no renderer. This is the headless seam.
  - `app.dart` + the views/panels/dialogs are the full-screen front end
    (`tina_console` renders it). Both regular and panel layouts use `SessionView`,
    which receives a host connection and presentation capabilities. It cannot
    reach the assembly or concrete runtime services. `tui_presentation.dart`
    currently adapts the assembly into feature view factories and a settings
    presenter; the latter still needs its own settings operation boundary.
  - `console_catalog.dart` constructs presentation views for existing runtime
    features. Plans use `tina_plans` for the runtime `PlansPlugin` and
    `tina_plans_tui` for a fresh `PlansView` per attachment, reading immutable
    snapshots through `PlanObservation`. Classification uses the runtime
    `ClassificationPlugin` from `classification` and an independent
    `ClassificationView` from `tina_classification_tui`, reading immutable
    trace snapshots through `ClassificationObservation`. View-local inspection
    commands are routed to the submitting attachment without replacing runtime
    command handlers. Step limits use a plain `StepLimitPlugin`; the generic
    Settings panel renders its declared setting, so it needs no custom console
    view. MCP uses a configured `McpPlugin` for connections, discovery, execution
    and session grants. Each `McpView` from `tina_mcp_tui` receives its settings
    capability, `McpManagement`; detaching a view releases only its settings
    registration and change subscription. Chat, activity, model controls, mode,
    context, updates, status layout and workspace panels also have fresh views.
    `tina_chat`, `tina_activity` and `tina_session_controls` own runtime state;
    frontend-only IDs use `PresentationPlugin` declarations. The runtime catalog
    imports no presentation package. Approval views receive a narrow interaction
    capability from the session-owned `AttachmentApprovalChannel`; dialog drafts
    and cancellation belong to each attachment.
  - `tui_terminal.dart` is the `Terminal` implementation a TUI session
    contributes: a text buffer plugins write lines into, and a queue of
    answers `ask` waits on. No terminal code in it despite the name.
- **tina_console** — rendering toolkit that knows nothing about agents,
  over `dart_notcurses` or plain ANSI. Used by the front end and by the
  `*_tui` plugin packages only.
- **plugins/\*** — feature plugins (tools, persistence, approvals,
  context, plans, goals, compaction, subagents, MCP, providers,
  self-update…). Registered by `plugin_catalog.dart` inside the assembly;
  enabled per global/workspace/session settings. The `*_tui` plugins
  depend on `tina_console`, never on the front end.

Per-package detail, where it exists:
[`tina_console/ARCHITECTURE.md`](../packages/tina_console/ARCHITECTURE.md),
[`tina_sqlite/ARCHITECTURE.md`](../packages/tina_sqlite/ARCHITECTURE.md),
[`plugins/tina_index/ARCHITECTURE.md`](../packages/plugins/tina_index/ARCHITECTURE.md).
Configuration is documented in
[`engine2-config.md`](engine2-config.md) and the pages beside it.

These boundaries are enforced: `tool/repository/policy.json` lists every
owned package and which ones may touch terminals; `tool/repository/test/`
runs the import checks in CI. The repository root has no Dart package. The
repository tooling package depends only on analysis/test libraries; it reads
application sources without importing their code. Application and library
packages cannot depend on repository tooling.

## The assembly seam

`TuiAssembly.start` builds the whole application without a screen:

```
AssemblyOptions (config path, cwd, store, session id, model, sandbox, …)
      │
TuiAssembly.start ──► config + scoped settings stack + plugin registry
      │                provider policy, ToolsPlugin (sandbox)
      └─► Host.start / Host.resume ──► AgentLoop + mounted plugins
```

The interactive path wraps it (`TuiSession.wrap`) and attaches the
renderer. The headless path (`--prompt`, `--goal`) runs turns against the
same assembly with no renderer and an approval channel that denies by
policy. Settings and plugin changes travel through config files plus the
assembly's configuration watcher — the assembly hot-reloads when they
change on disk.

The planned daemon split (see
[`proposals/daemon_sessions.md`](proposals/daemon_sessions.md)) separates
the application runtime from independent TUI attachments so one process
can own a live session while multiple clients observe it. The engine and
host already provide the foundation. Built-in runtime and presentation factories are now separate. Terminal notices,
configuration notifications and plugin lifecycle events have disposable observers;
Settings opens in the submitting attachment. Two in-process session views can
observe one runtime and close independently. A view releases its presentation;
the panel workspace delegates runtime cleanup to an optional application owner.
`runApp` owns embedded sessions and uses asynchronous host shutdown to drain
accepted runtime work before closing them. Closing a borrowed view does not
cancel its session; frontend `/quit` belongs to the invoking view. A cancellation
names work from the observed status and cannot stop a successor turn. Status
listeners run outside persistence callbacks and a failed observer is isolated.
The remaining work includes settings/provider management operations, correlated
non-approval questions and complete attachment snapshots, followed by moving
application composition to `apps/tina_cli`. Reusable contracts belong in
`tina_host`; no additional runtime package is planned. The current in-process
connection is not a transport protocol or an authorization boundary.

## Principles

- **One loop.** Every agent — interactive, headless, sub-agent, workflow
  node — runs the same `AgentLoop`.
- **One writer.** Only the loop appends to a session's log; everything
  else derives from it.
- **Contribution, not core, for anything swappable.** Renderers, extra
  tools, chat look: plugins. The loop, the permission precedence, the
  sandbox: baked in, exactly one implementation.
- **No interface without a second implementation.** The rendering backend
  is abstracted because there are two backends. The preparatory daemon work
  can use a concrete in-process session connection and shared value
  contracts; a transport interface gains its second implementation when
  the socket client is actually added.

Run `dart test` from the owning package directory; the repository root is not
a Dart package. CI selects affected packages and their dependents.
