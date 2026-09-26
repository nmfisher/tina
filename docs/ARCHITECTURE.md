# Architecture

tina is an agent runtime. An agent is a model session that acts through
tools: it streams from a provider, requests tool calls, passes each one
through a permission gate, and repeats until the model is done. tina
implements that loop once, plus the machinery every agent needs — context
building, sandboxed execution, permission checks, session persistence — and
a plugin system for everything that varies.

Nothing in the core assumes a terminal or a coding project; those are
contributions. The shipped binary mounts a terminal TUI and a headless
runner (`--prompt`, `--goal`) as hosts, plus the workspace tools that make
it a coding agent. This document explains the core first, then says what is
**baked in** and what is **mounted as a plugin**.

## The main loop

A turn is one cycle:

1. **Build the context.** The system prompt is assembled fresh (details
   below).
2. **Stream from the model.** Text deltas and tool-call requests arrive as
   events.
3. **Run tool calls through the permission gate.** Allowed calls execute
   inside the sandbox (a working set of writable paths). Denied calls
   return an explanation to the model. Everything else asks — an approval
   card in the TUI, the policy itself headless.
4. **Append results to the transcript and repeat**, until the model stops
   calling tools.

**The system prompt.** Rebuilt every turn, never stored: an identity
string; an environment block (working directory, OS, date, and a summary
of the current workspace); a read-only preamble when running in safe
mode. On top of that, whatever is mounted: project instructions read from
the repo, skill instructions, and plan/goal state injected by their
middlewares. Plugins can mount extra prompt sections — they trail the
built-ins and can extend them, but never reorder or shadow them.

**Where input comes from.** Usually a person: the TUI editor hands a line
to the session controller, which admits it as a user message. But a user
is optional. Headless, the input is the `--prompt` argument or stdin. A
`--goal` run synthesizes its own input: after each turn a judge model
reads the transcript against the goal and prepends a correction nudge
until the goal is met. Sub-agents get their prompt from the `delegate`
call that spawned them; workflow nodes get theirs from the pipeline
graph. The main place a person is consulted mid-run is an approval card —
headless, even that is answered by policy.

The cycle is bounded: step caps, a token budget that drops or summarizes
the oldest context, and a spend ceiling that stops the turn through the
normal error path. An interrupt injects a cancel signal into running tools
and the model stream; the transcript is persisted as it grows, so an
interrupted turn still ends cleanly and resumes.

This loop is written **once**, in the engine. TUI sessions, headless runs,
sub-agents, and workflow pipeline nodes all run it. The rest of tina
either feeds the loop (plugins, hosts, config) or observes it
(transcript rendering, status strip).

## Hosts

The core never talks to a terminal. A **host** combines the engine, the
app layer, and the console toolkit into a working frontend — and the host
is the only code that touches a terminal:

```
hosts (bin/ + lib/)         the ONLY code that touches a terminal
  TUI shell, headless runner, config, UI-shaped plugin descriptors
        |
tina_app                    application logic, terminal-free
  turn executor, interrupts, commands, plans/goals, workflows
        |
tina_engine                 the agent core, terminal-free
  the loop, model access, tools, sandbox, permissions, sessions,
  the plugin runtime
        |
tina_index, file_tree       pure support (graph, file listing)

tina_console -> dart_notcurses    terminal toolkit, used by hosts only
```

- **Engine** has no terminal dependency and no root-package dependency.
  That is why headless runs, sub-agents, and workflow nodes are the same
  loop as the interactive TUI — there is no second implementation to drift.
- **App layer** holds everything a non-terminal host would also need:
  session operations, command handling, plans, goals, workflow
  orchestration. A new host gets the whole application without a screen.
- **Console** is a rendering toolkit that knows nothing about agents —
  only strings, rectangles, and bytes — which keeps renderers pure and
  testable.
- **Hosts** pick what to mount: the TUI host and the headless host build
  the same runtime, then supply their own renderer set, command scope, and
  host seam (approval cards vs. policy answers).
- **Support packages** are domain-neutral: `tina_index` and `file_tree`
  know nothing about agents; `classifier` and `attractor` know nothing
  about terminals.
- **Only the hosts** combine the three. `test/architecture/` and
  `tool/architecture/` enforce these import boundaries in CI.

## The plugin system

The loop and its safety machinery are fixed. Everything around them —
transcript rendering, status-strip lines, extra tools, slash commands,
input observers — is contributed by **plugins**, so the same core serves
both hosts and any fork.

A plugin is a `PluginDescriptor`: an id, optional dependencies, and a
synchronous factory. The runtime validates the whole set up front (ids,
dependencies, cycles, colliding providers), activates in id order, and on
failure rolls back — nothing half-mounted. Inside the factory a plugin
registers services under `ServiceKey`s, requires services from other
plugins, and contributes to typed lists (tools, slash commands, status
sources, chat renderers). Id order is also override order: an id that
sorts earlier can wrap a later one — the timestamp chat overlay decorates
the built-in renderer that way.

Details — descriptor anatomy, the factory API, the full inventory of
built-in plugin ids and their defining files, and the implementation
record — are in [`docs/PLUGINS.md`](PLUGINS.md).

## Where things live

```
bin/tina.dart          entry point: parse args, pick host, run it
lib/                   the tina package (TUI shell, headless runner, config)
packages/
  tina_engine/         the agent core
  tina_app/            application layer
  tina_console/        terminal toolkit
  tina_index/          Dart dependency graph
  classifier/          structured judgments + exploration
  attractor/           DOT-based workflow pipeline runner
  file_tree/  fuzzy_ranker/  dart_notcurses/   small helpers
docs/                  this file, PLUGINS.md, features/, proposals/
test/  tool/           tests; codegen and architecture-policy scripts
```

Per-package detail lives inside the packages:

- [`packages/tina_engine/ARCHITECTURE.md`](../packages/tina_engine/ARCHITECTURE.md)
  — agent loop, LLM access, tools, permissions, sessions, plugin runtime.
- [`packages/tina_app/ARCHITECTURE.md`](../packages/tina_app/ARCHITECTURE.md)
  — runtime assembly, commands, plans, goals, workflows.
- [`packages/tina_console/ARCHITECTURE.md`](../packages/tina_console/ARCHITECTURE.md)
  — screen, regions, editor, backends.
- [`packages/tina_index/ARCHITECTURE.md`](../packages/tina_index/ARCHITECTURE.md)
  — the Dart dependency graph.
- [`packages/classifier/README.md`](../packages/classifier/README.md),
  [`packages/file_tree/README.md`](../packages/file_tree/README.md),
  [`packages/dart_notcurses/README.md`](../packages/dart_notcurses/README.md),
  [`packages/attractor`](../packages/attractor/),
  [`packages/fuzzy_ranker`](../packages/fuzzy_ranker/).

## The hosts

Two hosts ship. `bin/tina.dart` restores the terminal on crash, reaps
subprocesses on SIGTERM/SIGHUP, runs first-run setup, takes the session
lock, then picks one.

**Interactive.** `TuiCoordinator` (lib/tui_coordinator.dart) is the
composition root — runtime, screen, panels, focus, overlays.
`SessionController` (lib/session_controller.dart) owns the conversation set
and command dispatch. Around them:

- `lib/tui/` — panels, overlays, status renderers, approval cards, input.
- `lib/chat/` — transcript model: agent events → `ChatBlock`s → renderer
  rows; markdown.
- `lib/frontend/` — status `Renderer`s and per-conversation input state.
- `lib/host/` — `TuiConversationHost` (approval prompts become cards).
- `lib/completion/` — file and command providers for the palette.
- `lib/session_commands/` — slash commands, registry, session picker.
- `lib/composition/` — the TUI's plugin descriptors (ids inventoried in
  `docs/PLUGINS.md`).
- `lib/config.dart` + `lib/config/` — TOML config, env, CLI flags → typed
  settings.
- `lib/tmux/`, `lib/self_update/`, `lib/platform/` — tmux attach; `/update`
  (download, verify sha256, swap binary); terminal geometry.

**Headless.** Same runtime assembly, the engine's `HeadlessHost` in place
of the TUI host, stdout/stderr for output. `--goal` wraps the run in the
goal loop (run → judge → repeat;
[`docs/features/goal_mode.md`](features/goal_mode.md)); the headless
watchdog (lib/host/) kills silent hangs.

## Principles

- **One loop.** Every agent — interactive, headless, sub-agent, workflow
  node — runs the same engine loop with a different host.
- **Contribution, not core, for anything swappable.** Status renderers,
  extra tools, chat look: descriptors. The loop, the permission
  precedence, the sandbox: baked in, exactly one implementation.
- **No interface without a second implementation.** `Agent`, `Screen`,
  and the regions are concrete; the editor keymap is hardcoded. The
  rendering backend is abstracted only because there are genuinely two
  backends.

`dart test` at the repo root runs everything; packages test themselves.
