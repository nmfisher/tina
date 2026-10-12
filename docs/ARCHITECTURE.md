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
apps/tina_cli               application (package tina): composition, configuration, CLI and lifecycle
packages/tina_tui           reusable terminal views, dialogs and render loop
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
- **tina** (`apps/tina_cli`) — the executable application and composition root.
  `SessionAssembly` in `assembly.dart` loads configuration, builds the scoped
  settings stack, runtime plugin registry, provider policy and sandbox, then
  starts or resumes a `Host`. Its public `session.dart` entry point has no
  transitive terminal dependency. `Terminal`, writer and provider factory remain
  injectable. `SessionTerminal` buffers notices and ordinary question answers
  without physical terminal I/O.
  - `cli.dart` routes interactive TUI, headless `--prompt`/`--goal`, configuration,
    model listing, resume and import. The app owns release version, process
    startup and restart, plus reading the store for resume selection.
  - `console_catalog.dart` constructs fresh presentation views for existing
    runtime features. `tui_presentation.dart` supplies those factories and
    settings operations to the reusable frontend. `ConfigSettingsManagement`
    keeps configuration documents, credentials and plugin management private.
  - `tui.dart` is the terminal composition entry point. `TuiSession` connects an
    assembled session to its presentation; `runTui` supplies creation and shutdown
    callbacks to the render loop. Libraries and plugins cannot depend on the app.
- **tina_tui** — reusable terminal presentation with no concrete plugin,
  configuration or persistence dependency. `SessionView` receives a disposable
  host connection and presentation capabilities. Normal and panel layouts use
  the same view. `runApp` receives application callbacks for session creation
  and cleanup; without an owner callback, exit detaches a borrowed view and its
  session continues. Settings/provider dialogs receive `SettingsManagement`
  operations and sanitized data; `tina_settings` supplies immutable snapshots
  and revision-checked edits. The resume picker accepts display-only
  `SessionChoice` records and never opens a store.
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

`SessionAssembly.start` builds the whole application without a screen:

```
AssemblyOptions (config path, cwd, store, session id, model, sandbox, …)
      │
SessionAssembly.start ──► config + scoped settings stack + plugin registry
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
`runTui` in the CLI owns embedded sessions and uses asynchronous host shutdown to drain
accepted runtime work before closing them. Closing a borrowed view does not
cancel its session; frontend `/quit` belongs to the invoking view. A cancellation
names work from the observed status and cannot stop a successor turn. Status
listeners run outside persistence callbacks and a failed observer is isolated.
Settings dialogs no longer receive a backend, plugin manager, provider factory
or credential-bearing config document. Each confirmed edit checks the revision
it began with. Provider drafts expose public fields and credential presence;
keep/replace/clear operations apply secrets inside the configuration adapter.
Application composition now lives in `apps/tina_cli`, with transitive import
checks for its headless entry point and the reusable TUI. The remaining work
includes correlated non-approval questions and complete attachment snapshots. Reusable contracts belong in
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
