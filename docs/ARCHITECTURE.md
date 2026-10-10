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
bin/tina.dart               entry point: initializeProcessLauncher, runCli
packages/tina_tui           the app: CLI router, assembly, terminal front end
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
  before opening resources and roll back on failure. Terminal-free.
- **tina_llm** — `LlmProvider` implementations and the provider
  descriptors the config system reads.
- **tina_tui** — the application and its front end in one package today:
  - `cli.dart` parses flags and routes: interactive TUI, headless
    `--prompt`/`--goal`, `--configure` editor, `--models` listing,
    `--resume`/`--continue` picker, `--import-sessions`.
  - `assembly.dart` (`TuiAssembly`) is the composition root: loads
    config, builds the scoped settings stack, the plugin registry, the
    provider policy, the `ToolsPlugin` sandbox, and starts or resumes the
    `Host`. Everything it needs is injectable (`Terminal`, writer,
    provider factory), so a test — or a daemon — runs the whole app with
    no renderer. This is the headless seam.
  - `app.dart` + the views/panels/dialogs are the full-screen front end
    (`tina_console` renders it).
  - `tui_terminal.dart` is the `Terminal` implementation a TUI session
    contributes: a text buffer plugins write lines into, and a queue of
    answers `ask` waits on. No terminal code in it despite the name.
  - `process_launcher.dart` is the FFI process spawner the tools use; the
    binary initializes it before anything else runs.
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

These boundaries are enforced: `tool/architecture/policy.json` lists every
owned package and which ones may touch terminals; `test/architecture/`
runs the import checks in CI.

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
the assembly half of `tina_tui` from the front end half so a daemon
process can own live sessions and the TUI can become a client of it. The
assembly seam above is what makes that a file move, not a rewrite.

## Principles

- **One loop.** Every agent — interactive, headless, sub-agent, workflow
  node — runs the same `AgentLoop`.
- **One writer.** Only the loop appends to a session's log; everything
  else derives from it.
- **Contribution, not core, for anything swappable.** Renderers, extra
  tools, chat look: plugins. The loop, the permission precedence, the
  sandbox: baked in, exactly one implementation.
- **No interface without a second implementation.** The rendering backend
  is abstracted because there are two backends; the daemon work adds the
  second `SessionClient` implementation (in-process, socket) that
  justifies that seam.

`dart test` at the repo root runs everything; packages test themselves.
