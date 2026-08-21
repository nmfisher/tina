# Architecture

`tina` is a small terminal coding agent written in Dart. It streams a chat
loop against an LLM, lets the model call a set of tools (read / write /
edit / bash / grep / glob / search), gates those calls through a permission
policy, persists the conversation to disk, and renders everything through
a raw-mode line editor that ships as its own reusable package.

This doc explains where things live and why they're split the way they are.

## Top-level layout

```
tina/
  bin/
    tina.dart              — entry point: parse flags, wire deps, run
  lib/                       — the app: TUI, wiring, sessions
    config.dart              — CLI + env parsing → Config
    repl.dart                — interactive loop, slash commands
    tui_coordinator.dart     — TUI construction + lifecycle wiring
    chat_agent_sink.dart     — AgentSink impl that renders to chat panel
    conversation.dart        — one conversation (agent + history + chat region)
    session.dart             — workspace holding one or more Conversations
    session_manager.dart     — session factory + lifecycle
    message_queue.dart       — queued-message buffer (typing during execution)
    composition/             — dependency wiring: tools → agent → sessions
    completion/              — git-aware file-path completion provider
    config/                  — user config (~/.tina/config.toml) + provider registry
    host/                    — conversation host surface the TUI drives
    persistence/             — session restore (the store itself is in tina_engine)
    pipeline/                — workflows: supervisor, pipeline runner, tools
    platform/                — platform / environment detection
    project/                 — project-level state
    regions/                 — region agents + allocation
    session_commands/        — slash-command implementations
    summaries/               — summary index + fleet summaries
    tui/                     — panels, settings, TUI widgets
  packages/
    tina_engine/           — agent loop, providers, tools, permissions (own pubspec)
    tina_console/          — reusable raw-mode console toolkit (own pubspec)
    tina_index/            — AST-derived code dependency graph (own pubspec)
    fuzzy_ranker/          — fuzzy ranking + CompletionProvider interface (own pubspec)
    attractor/             — DOT-based multi-agent pipeline runner (own pubspec)
    dart_notcurses/          — Dart FFI bindings to notcurses (own pubspec)
  examples/                  — example workspace fixture for driving tina
  docs/                      — design docs (agent pipeline, tool strip, graph search …)
  tool/                      — dev utilities (render_to_image, visual_test, build)
  test/                      — tests for tina proper

```

The split between `lib/` and `packages/tina_console/` is the most important
boundary in the project — see [Six packages, on purpose](#six-packages-on-purpose).

## Six packages, on purpose

The repo is a monorepo with six Dart packages.

**`tina`** (root) is the app. It depends on the others via path
dependencies in `pubspec.yaml`.

**`tina_engine`** (`packages/tina_engine/`) is the agent runtime: the
tool-calling loop and its output sink, the LLM provider abstraction and
wire-format adapters, the tool registry and built-in tools, the permission
policy, and session persistence. It has no terminal / UI dependencies —
the app supplies the sink, the permission asker, and the I/O.

**`tina_console`** (`packages/tina_console/`) is a generic raw-mode
console toolkit built around a `Screen` chokepoint that owns the stdout
sink, a `ScreenLayout` value type, frame borders, and a small set of
`Region` write surfaces (chat, status, input, overlays). It also ships
an async line editor that renders into the input region, plus an
`@`-trigger completion picker, fuzzy ranking, a `MenuBar`, and a
pluggable `TerminalBackend` / `InputBackend` pair that lets the same
`Screen` render through ANSI escapes or notcurses. It has no agent / LLM
/ tool dependencies and could drop into any other Dart CLI unchanged.

**`tina_index`** (`packages/tina_index/`) is an AST-derived code
dependency graph for Dart codebases. It parses `.dart` files into
`Symbol`s (functions, classes, methods, fields), builds typed `Edge`s
(extends, implements, imports, contains), persists the graph to disk via
`GraphStore`, and supports seeded traversal (`GraphTraversal`) and
keyword-based matching (`seedQuery`). The app's `SearchTool` and
`SummaryGenerator` consume it; the package itself has no agent / LLM
dependencies.

**`fuzzy_ranker`** (`packages/fuzzy_ranker/`) is subsequence-fuzzy
matching/ranking plus the pluggable `CompletionProvider` interface — the
neutral seam shared by the TUI toolkit and the app's completion sources.
Pure Dart, no terminal or engine dependencies.

**`attractor`** (`packages/attractor/`) is a DOT-based pipeline runner:
directed graphs (Graphviz DOT) that orchestrate multi-stage agent
workflows. UI- and LLM-agnostic; consumed by the app's pipeline layer.

**`dart_notcurses`** (`packages/dart_notcurses/`) is a Dart FFI wrapper
around the notcurses C library — `Notcurses`, `Plane`, `Cell`, `Channels`,
`Visual`, `Menu`, `Direct`, `Reader`, and key-code constants. It ships
pre-built native libraries for macOS arm64 and provides the rendering
backend that `tina_console`'s `NotcursesBackend` delegates to.

The boundary between app and console exists because the console code is
*what would be most reusable elsewhere*, and isolating it forces the app
code to talk to it through a narrow surface (a barrel export, a couple of
interfaces). The split also makes everything testable without a TTY: a
`FakeStdio` records the bytes the `Screen` emits, and a `VirtualTerminal`
interprets them so tests can assert on the final on-screen state.

## Inside `lib/` — by layer

The dependency direction is roughly: entry → tui_coordinator →
repl/config / composition → session_manager → conversation →
(tina_engine) agent → tools / llm / permissions / persistence. Lower
layers don't import higher ones, and nothing in `tina_engine` imports
anything from the app.

### `bin/tina.dart` — entry point

Parses `Config`, builds the provider and policy, and either runs a
one-shot non-interactive turn (`--prompt "…"`) or hands control to
`TuiCoordinator` which constructs the interactive TUI. Owns the raw-mode
terminal lifecycle: flips `stdin.echoMode`/`lineMode` off, calls
`screen.enterAltScreen()`, installs SIGINT and SIGWINCH handlers, and
restores everything in `finally`. Nothing else in the codebase touches
the terminal modes — that responsibility lives entirely here so a crash
anywhere can't leave the user's shell broken.

Most of the dependency wiring (tools, agent, sessions, editor, screen)
has moved into `TuiCoordinator` — the entry point stays thin so the
non-interactive and interactive paths share provider/policy construction
but diverge cleanly on UI setup.

### `lib/config.dart` — CLI + env resolution

`Config.parse(argv, env)` is the single source of truth for "what did the
user ask for?" It resolves provider, API key (Anthropic supports both
`ANTHROPIC_API_KEY` and bearer-style `ANTHROPIC_AUTH_TOKEN` for compat
layers), model, base URL, permission rules, session flags, and yolo mode.
Cross-flag validation (`--resume` and `--continue` are mutually exclusive)
lives here, not in the REPL.

`Config.buildPolicy()` is the one piece of cross-layer glue — it knows how
`--yolo` collapses into `PermissionPolicy.defaults`. That coupling is
deliberate: a CLI flag *is* a policy override, and routing it through a
separate factory would just spread the knowledge.

### `lib/repl.dart` — interactive loop

The REPL is the human-facing driver. It owns:

- the in-memory `List<Message> history`,
- the read-print loop calling `editor.readLine('> ')`,
- slash commands (`/help`, `/clear`, `/compact`, `/model`, `/permissions`,
  `/sessions`, `/resume`, `/exit`),
- the cancellation wiring (ESC during a turn → `editor.beginCancelMonitor`
  → `Completer` → `agent.run(cancelSignal: …)`),
- writing each new history message to the `SessionRecorder` after a turn.

The REPL does **not** know how the agent talks to the model, how tools
execute, or how permissions are checked. It sees `Agent`, `Screen` (only
`screen.chat` and `screen.clearChat()` for `/clear`), `LineEditor`,
`SessionRecorder`, and the `Message` model. The non-interactive path in
`bin/tina.dart` reuses `Agent` directly without involving any REPL code,
passing a passthrough `Screen.chat` so output goes to plain stdout.

### `packages/tina_engine/lib/src/agent/` — the tool-calling loop

(Moved out of the app's `lib/` when the engine became a package; the
structure below is unchanged apart from the new neighbours.)

`Agent.run(system, history, userInput, cancelSignal)` is the harness:

```
add user message
loop (up to maxSteps):
  stream a provider response (TextDelta + ToolCallStart events → live render;
    MessageComplete → assembled content + usage)
  append assistant message
  if no ToolUseBlocks: done
  for each tool use:
    policy.check(name, input)
      → allow:  execute, append ToolResultBlock
      → deny:   skip, append error ToolResultBlock
      → ask:    PermissionAsker → repeat
  append user message with all ToolResultBlocks
```

`Agent.compact(history)` is a second public entry point: it asks the model to
summarize the conversation and replaces `history` with a two-message
synthetic exchange (summary as user, "got it" as assistant). The
`_compactSystemPrompt` lives next to the code that uses it.

The agent never writes to a UI directly — all output goes through an
`AgentSink` (see below). This is what lets the same `Agent` serve the
interactive chat panel, a non-interactive stdout path, or a future tool
strip without the loop knowing the difference.

- **`agent_sink.dart`** — the output interface. `AgentSink` defines
  `text()`, `newline()`, `toolStart()`, `toolOutput()`, `toolComplete()`,
  and `notice()` payload methods. The agent says *what happened*; the sink
  decides *how to render it*. Also holds the `ToolEvent` payload types
  (`ToolStartEvent`, `ToolOutputEvent`, `ToolCompleteEvent`) and the
  `NoticeKind` enum. The agent layer never imports a UI type — this file
  only references `Tool` from `tools/tool.dart`.
- **`stream_consumer.dart`** — `ProviderStreamConsumer`: extracted from
  `Agent`, handles the `Completer` / subscription / cancellation
  choreography for a single provider stream. Returns a `TurnOutcome` with
  the assembled content. Stateless: all rendering goes through the
  `AgentSink` passed to `consume`, so this class holds no UI references
  and can be tested in isolation.
- **`system_prompt.dart`** — the long-form instruction string + an
  `<environment>` block describing platform, cwd, model. Kept separate
  from `agent.dart` so the prompt can grow without bloating the loop.
- **`token_budget.dart`** — `TokenBudget`: optional caps on token
  consumption (per-turn, per-session, per-request input) that protect
  against runaway loops — a tool that keeps re-firing, a malformed prompt
  that produces unbounded output, etc. Defaults are generous; a normal
  coding session should never hit them. Per-session counters reset on
  `/clear`.
- **`summary_generator.dart`** — `SummaryGenerator`: LLM-based code
  summarization driven by `tina_index`'s `CodeGraph`. Walks stale
  symbols, asks the model to summarize each function / class, and writes
  the results back to the graph store. Supports dry-run counting
  (`countPending`) for progress reporting.
- The directory has grown neighbours since the move — `agent_pipeline`,
  `agent_event_bus`, `sub_agent_scheduler` / `sub_agent_sink`,
  `spend_ledger`, `agent_quota`, `pause_gate` — which extend the same
  loop with streaming pipelines, fleet scheduling, and metering.

### `packages/tina_engine/lib/src/llm/` — provider abstraction

This is the hardest boundary in the project, and the one that buys the most.

- **`message.dart`** — the canonical conversation model. `Message`,
  `Role`, and the sealed `ContentBlock` hierarchy
  (`TextBlock` / `ToolUseBlock` / `ToolResultBlock`). The JSON shape
  intentionally mirrors Anthropic's wire format — that's enough provider
  neutrality for our purposes, keeps persistence files human-readable, and
  the OpenAI adapter is the one place we pay the translation cost.
- **`provider.dart`** — the `LlmProvider` interface plus the
  `StreamEvent` hierarchy (`TextDelta`, `ToolCallStart`, `MessageComplete`,
  `StreamError`). Providers do all SSE assembly internally and emit deltas
  for *live display* and one final `MessageComplete` the agent uses for
  *logic*. `TokenUsage` is a value type used by both providers and the agent.
- **`sse.dart`** — a 14-line `data:` line parser shared by both adapters.
- **`http.dart`** — shared HTTP plumbing used by every provider. Retry
  logic with exponential backoff, timeouts, `Retry-After` honouring (with
  a cap), and error humanization. Lives in its own file so `openai.dart`
  doesn't reach into `anthropic.dart` for transport concerns, and so the
  retry / timeout behaviour can be tested in isolation from any specific
  provider's wire format.
- **`anthropic.dart`** — adapter for `/v1/messages`.
- **`openai.dart`** — adapter for `/v1/chat/completions` (and any
  OpenAI-compatible server via `--base-url`).
- **`openai_compatible.dart` / `gemini.dart`** — further adapters over the
  same `Message` model.
- **`pooled_provider.dart`** — a pool decorator: N equivalent providers
  serving one model, rotated round-robin to multiply a per-key rate limit
  (three 40-RPM members ≈ 120 RPM aggregate). Failover happens before any
  content streams; a failed member cools down and is skipped. Config
  declares one as `[providers.<id>] members = [...]`; see
  `lib/composition/config_providers.dart`.
- **`registry.dart` + `providers/`** — the provider registry: one
  descriptor file per built-in provider (anthropic, openai, glm, gemini,
  grok, mistral, …) carrying wire format, model catalog, and auth shape.
  User config can override built-ins or add new provider ids.

The adapters are the *only* code that knows wire-format details: header
shapes, tool-call delta accumulation, the difference between Anthropic's
`tool_result` blocks and OpenAI's separate `role: "tool"` messages.
Everything above this layer thinks in `Message` + `ContentBlock`.

### `packages/tina_engine/lib/src/tools/` — tool interface + implementations

`tool.dart` defines `Tool` (a `schema` + `execute(input)`), `ToolSchema`,
`ToolResult`, and a `ToolRegistry` keyed by tool name.

The built-ins (the original seven — read, write, edit, bash, grep, glob,
search — plus later additions like delegate, fetch, channel, and the
search-provider tools) each live in their own file. Each is responsible
for its own schema, validation, and execution. The agent never
special-cases any of them — `tools[use.name]?.execute(use.input)` is the
whole dispatch. Adding a tool means writing one file and registering it in
`buildTools()` in the app's `lib/composition/agent_composition.dart`.

- **`read_tool.dart`** — read file contents (with optional offset / limit).
- **`write_tool.dart`** — write / overwrite a file atomically.
- **`edit_tool.dart`** — exact-string replacement in a file.
- **`bash_tool.dart`** — execute a shell command, stream stdout / stderr.
- **`grep_tool.dart`** — search file contents for a regex pattern. Tries
  ripgrep first; falls back to a pure-Dart walk if `rg` isn't on PATH.
  Results are capped at a configurable maximum.
- **`glob_tool.dart`** — find files matching glob patterns. Uses
  `git ls-files` when available; otherwise walks the directory tree
  skipping common build directories. Shares its file enumeration helpers
  with `grep_tool.dart`.
- **`search_tool.dart`** — search the code dependency graph for a symbol.
  Delegates to `tina_index`'s `CodeGraph` for symbol lookup, edge
  traversal (extends, implements, imports), and source retrieval. Returns
  related symbols, their relationships, and source code.

### `packages/tina_engine/lib/src/permissions/` — gating

Permission decisions are a separate layer because they cut across tools,
config (`--allow`/`--deny`/`--yolo`), CLI display (`/permissions`), and the
agent loop (gate before execute).

- **`policy.dart`** — `PermissionPolicy` holds per-tool defaults,
  CLI-provided `staticRules`, and a `sessionRules` list that grows as the
  user picks "always" in prompts. `check(tool, input)` returns
  `allow` / `deny` / `ask`. Also contains:
  - `keyFor(tool, input)` — turns a tool call into a single string used
    for matching and display (the command for `bash`, the path for file
    tools).
  - `defaultAlwaysPatternFor(tool, input)` — the broader pattern offered
    when the user picks "always" (e.g., `git *` for `git status`, or
    `lib/foo/*` for a write to `lib/foo/bar.dart`).
  - `globMatch(pattern, input, starMatchesSlash:)` — tiny shell-style
    glob matcher. `*` stops at `/` for file tools so a single approval
    doesn't accidentally cover sibling directories; for bash command
    patterns `*` spans everything.
- **`prompt.dart`** — `PermissionPrompt` + `PermissionResponse` types and
  the `PermissionAsker` typedef. The actual question UI lives in
  `bin/tina.dart` (raw-mode keystroke) and `_runNonInteractive` (always
  denies with a hint to use `--allow` or `--yolo`). Decoupling lets tests
  inject a deterministic asker.
- **`preview.dart`** — tool-call preview rendering for the permission
  modal. A sealed `PreviewEntry` hierarchy (`PreviewHeader`, `PreviewLine`,
  etc.) represents the rendered lines as data (not pre-colored strings)
  so generation is unit-testable. Write / edit previews use an LCS-based
  diff; large files skip the diff pass to avoid O(m×n) cost. Previews are
  capped at a configurable line count — the user can rely on git or their
  editor for the full picture.

### `lib/persistence/` + `packages/tina_engine/lib/src/persistence/` — sessions

- **`session_store.dart`** (engine) — abstract `SessionStore` (create / append /
  replace / load / list / delete / close) plus `SessionMeta` and
  `SessionRecorder`. The interface is intentionally narrow: REPL-level
  operations only, no schema concerns. Swapping JSONL for SQLite or a
  remote backend means implementing one class.
- **`jsonl_session_store.dart`** (engine) — the only concrete
  implementation today. One JSONL file per session at
  `~/.tina/sessions/<id>.jsonl`. Append uses `FileMode.append` + flush;
  `replace` writes a tempfile and renames for atomic `/compact` swaps.
- **`session_restore.dart`** (app) — rebuilding live conversation state
  from a persisted session on `--resume` / `--continue`.

`SessionRecorder` is the REPL-side wrapper that holds the active session
id and an `enabled` flag (so `--no-save` short-circuits writes without
the REPL needing to branch on it). Keeping "which session am I in?" out of
the store interface means a backend can be stateless.

### `lib/completion/` — file-path completion

`GitFileCompletionProvider` implements the `CompletionProvider` interface
from `tina_console`. It enumerates files via
`git ls-files --cached --others --exclude-standard` (so `.gitignore` is
honored by `git` itself), falling back to a directory walk that skips
common build dirs when not in a git repo. Results are cached in-process;
fuzzy ranking comes from `tina_console`'s `rankFuzzy`.

This implementation lives in the app, not in the console package, because
it knows about git and file systems — both project-specific concerns.
The package just defines the interface; the app supplies the source.

### `lib/tui_coordinator.dart` — TUI wiring

Owns the interactive TUI construction and lifecycle. Created by
`_runInteractive` in `bin/tina.dart`, the coordinator keeps all UI
feature wiring in one place so new features can be added without
touching the top-level entry point. It:

- selects and instantiates the `TerminalBackend` (ANSI or notcurses,
  probed at startup via `isNotcursesAvailable()`),
- builds the `Screen` with the chosen backend,
- constructs the tool registry via `buildTools()`,
- creates the `SessionManager` with provider and permission-asker
  factories,
- sets up the `LineEditor`, `MenuBar`, `FocusManager`, and signal
  handlers (SIGINT, SIGWINCH).

`buildTools()` lives here (not in `bin/tina.dart`) — it's the single
place that enumerates the seven built-in `Tool` implementations.

### `lib/chat_agent_sink.dart` — interactive output sink

`ChatAgentSink` implements `AgentSink` by routing agent output to the
chat panel (`ChatRegion`). It is the only `AgentSink` implementation
that imports `tina_console` — the agent layer stays UI-agnostic.
When the tool strip lands, the host layer will swap this for a composing
sink that routes tool events to the strip and skips them on chat while
leaving text / notices on chat. The agent is oblivious to which sink
it has.

### `lib/conversation.dart` — a single conversation

A `Conversation` bundles one agent, one provider, one permission policy,
one chat region, one history (`List<Message>`), and one `MessageQueue`.
It lives inside a `Session` (which may hold several conversations, each
with its own model or provider). Conversations are independent — each
can run a different model, carry its own cancel completer, and render
to its own chat region.

### `lib/session.dart` — multi-conversation workspace

A `Session` is the container that carries account context (provider kind,
API key, base URL) and holds one or more `Conversation`s. Today every
session has exactly one conversation, but this container is the seam
that will let a session grow several — each with differing tools and
permissions. The `SessionManager` owns the live set and routes the
active conversation to the screen.

### `lib/session_manager.dart` — session lifecycle

Factory and lifecycle for sessions. `SessionManager` constructs
`Session`s, manages conversation creation, and provides
`ProviderFactory` and `AskerBuilder` callbacks (supplied by the app
layer) so the manager stays decoupled from concrete provider
implementations and permission-asker UIs.

### `lib/message_queue.dart` — queued input

A simple `Queue<String>` wrapper. When the user types during agent
execution, the input is enqueued rather than lost. After the current
turn finishes, the REPL drains the queue and runs each message as a
new turn.

## Inside `packages/tina_console/`

The console package is built around one chokepoint — `Screen` — that owns
the stdout sink, the cursor, and the frame borders. Everything visible on
the terminal is written to a **Region** within the screen; regions clip
every write to their bounds, and the screen automatically repaints frame
borders on any row a write touched. There is no path for code outside
`Screen` to emit ANSI escapes or position the cursor.

```
packages/tina_console/
  lib/
    tina_console.dart      — barrel: exports everything below
    src/
      screen.dart            — Screen: the only stdout writer
      screen_layout.dart     — ScreenLayout: rectangles for every region
      region.dart            — Region base + ChatRegion / StatusRegion /
                               InputRegion / OverlayRegion
      rect.dart              — Rect value type
      spinner.dart           — Spinner (no-op; animation retired) /
                               ProgressCounter (StatusRegion writers)
      line_editor.dart       — async raw-mode editor (renders into InputRegion)
      confirm_dialog.dart    — Ctrl-C confirmation (owns an OverlayRegion)
      completion_picker.dart — @-popup (owns an OverlayRegion)
      completion.dart        — CompletionProvider interface
      input_parser.dart      — byte → InputEvent decoder
      input_event.dart       — sealed InputEvent hierarchy
      line_edit.dart         — buffer model: cursor, history, kill ring
      line_layout.dart       — pure layout math (kept; tests still use it)
      ansi_capable.dart      — ANSI support detection
      ansi_wrap.dart         — ANSI-safe column wrapping
      fuzzy.dart             — fuzzyScore, rankFuzzy
      stdio.dart             — Stdio interface (stdin/stdout/terminalColumns)
      panel.dart             — Panel: Region + Focusable + a BackendSurface
      text_panel.dart        — minimal framed panel (reference impl + test target)
      focusable.dart         — Focusable interface
      focus_manager.dart     — focus ring; routes input to the focused panel
      menu_bar.dart          — desktop-style menu bar (top row, dropdown overlays)
      menu.dart              — Menu / MenuItem / MenuSeparator model
      info_panel.dart        — passive content panel for the info box
      tool_chip.dart         — ToolChip: per-tool-call UI state (running /
                               success / error) for the tool strip
    backend/
      terminal_backend.dart  — abstract rendering interface (moveCursor /
                               eraseCells / writeText / flush)
      input_backend.dart     — abstract input source (Stream<InputEvent>)
      ansi_backend.dart      — ANSI escape-sequence TerminalBackend
      ansi_input_backend.dart— wraps Stdio.stdin through InputParser
      notcurses_backend.dart — notcurses-backed TerminalBackend (real ncplanes)
      notcurses_input_backend.dart — wraps native key events
      notcurses_probe.dart   — isNotcursesAvailable(): safe FFI probe
      backend_factory.dart   — BackendFactory typedef
      backend_surface.dart   — BackendSurface: plane handle for panels
  test/
    screen_test.dart, screen_layout_test.dart,
    screen_backend_lifecycle_test.dart
    region_chat_test.dart, region_status_test.dart,
    region_input_test.dart, region_overlay_test.dart
    line_editor_test.dart, line_editor_input_backend_test.dart,
    spinner_test.dart, confirm_dialog_test.dart, completion_picker_test.dart,
    menu_bar_test.dart
    render_pipeline_test.dart      — end-to-end frame-integrity invariants
    backend_contract_test.dart, backend_factory_test.dart,
    input_backend_test.dart, ansi_input_backend_lifecycle_test.dart,
    notcurses_backend_test.dart, notcurses_backend_platform_test.dart,
    notcurses_backend_visible_columns_test.dart,
    notcurses_translate_key_test.dart
    line_edit_test.dart, line_layout_test.dart, input_parser_test.dart,
    fuzzy_test.dart, ansi_capable_test.dart,
    panel_test.dart, focus_manager_test.dart
    virtual_terminal.dart, stdio_fake.dart  — test infra
```

### Screen, the chokepoint

`Screen` holds the `ScreenLayout`, an `AnsiCapable` flag, references to
the regions, and a `TerminalBackend` that does all actual rendering.
The screen delegates positioning, erasing, and writing to the backend —
keeping layout logic and clipping in `Screen` itself while the backend
handles the encoding (ANSI escape sequences or notcurses API calls).
Backend operations are batched: callers build up a sequence of
`moveCursor` / `eraseCells` / `writeText` calls, then `flush` sends
them to the terminal.

Internally the screen offers two clipping primitives —
`putAtAbsolute(row, col, text, maxCols, moveCursor)` and
`eraseAtAbsolute(row, col, n, moveCursor)` — that every region routes
writes through. Both:

1. clip the text to `maxCols` visible cells (ANSI escapes don't count),
2. emit `\x1b[NX` to erase the slot first, so partial overwrites don't
   leave stale chars,
3. re-emit any frame-border cell that lives on the touched row.

That last step is the load-bearing invariant: **borders cannot be eaten**,
because they're rewritten after every region write whether or not the
region intended to touch them. No caller in the codebase ever invokes a
"repair" sequence — it can't, because the methods that emit ANSI are
inside `Screen` and they always do the repair themselves.

`Screen.enterAltScreen()` flips into the alt-screen buffer and draws the
frame once; `redrawFrame()` is called from there and again on
`resize(newLayout)`. `clearChat()` erases the chat region (preserving the
frame). `parkCursorAt(row, col)` is called by [InputRegion] to put the
visible cursor where the user is editing — this is the only API that
moves the cursor without also writing content.

A `Screen.passthrough(stdio)` constructor produces a degenerate screen
for `--prompt` and piped runs: no alt-screen, no frame, regions become
straight `stdio.write` wrappers. The same `Agent` code runs against
either — non-interactive callers see plain stdout, interactive ones get
the full panel layout.

### Regions

Four region subclasses, each with a narrow purpose:

- **`ChatRegion`** is the streaming chat panel. It keeps a row buffer the
  size of `bounds.height`, advances a write pointer character-by-character
  wrapping at `bounds.width`, and scrolls within its own bounds when more
  content arrives than fits. ANSI escapes pass through but don't consume
  column budget. Convenience colour methods (`dim`, `cyan`, `green`,
  `yellow`, `red`, `color(code, s)`) and a `separator()` helper exist for
  the REPL.
- **`StatusRegion`** is random-access by row. `writeAt(relRow, text)` and
  `clearAt(relRow)` use save/restore so the visible cursor (parked by
  `InputRegion`) doesn't move when an overlay updates. Used by `Spinner`
  and `ProgressCounter`.
- **`InputRegion`** renders prompt + buffer + cursor on a single row at
  `layout.input`. When `prompt + buffer` exceeds the width it scrolls
  horizontally (zsh/fish/readline behaviour) so the cursor stays visible —
  it never grows upward into the chat region or the separator row.
- **`OverlayRegion`** is an absolutely-positioned floating panel for
  modals (`ConfirmDialog`, `CompletionPicker`). `show(lines)` writes its
  rectangle; `hide()` blanks it and triggers border repair. Bounds are
  clipped to the screen; `reposition()` moves the overlay (clearing the
  old rectangle).

Regions do not own a cursor model. They do not know what an ANSI escape
looks like. They cannot emit a stray `\n` because the only output method
is `screen.putAtAbsolute(...)`. When you write a new region type, it gets
the same guarantees for free.

### ScreenLayout

`ScreenLayout.fromSize(width, height, {hasMenuBar})` is a pure function
returning the absolute `Rect` for each region plus border-row /
border-column indices. Two modes:

- *Single panel* (width < 100): chat fills the area above the input row;
  no borders, no info box (`info.isEmpty == true`).
- *Split* (width ≥ 100): chat occupies the left 60% of the interior,
  info occupies the right 40%, separated by a `│` divider with a
  `├─┼─┤` separator row above the input row, and `┌──┬──┐` / `└──┴──┘`
  on the top and bottom. The layout records every border cell's
  identity via `borderCharFor(row, col)` so `Screen` can repaint them
  without conditional logic.

The layout also accounts for an optional **menu bar** row at the top
(`hasMenuBar`). When present, it occupies row 0 with a 3-row box
(border / content / border), pushing the chat / info top borders down.
The `status` getter is an alias for `info` — kept for backwards
compatibility with callers that predate the rename.

Layout state lives in exactly one place — `Screen._layout`. Regions
recompute their bounds on every access via `screen.layout.chat` etc.
`Screen.resize(newLayout)` swaps it atomically and asks each region to
`handleResize()`.

### LineEditor

`LineEditor` is the async raw-mode editor. It owns a `LineEdit` (buffer +
cursor + history + kill ring), an `InputBackend` (abstract input source —
either `AnsiInputBackend` wrapping stdin through `InputParser`, or
`NotcursesInputBackend` wrapping native key events), a `ConfirmDialog`,
a `CompletionPicker`, and optionally a `MenuBar`. Every redraw is one
call:

```dart
screen.input.render(prompt: …, buffer: edit.buffer, cursor: edit.cursor);
```

The editor doesn't track row counters, doesn't walk the cursor up before
clearing, doesn't emit border sequences — that complexity is gone. The
picker and dialog overlays render themselves on demand and clean up via
`OverlayRegion.hide()`.

The `MenuBar` (when set via `editor.menuBar = …`) gets first crack at
input events: when active it consumes all navigation keys (arrows,
Enter, Esc) and routes selections to menu item callbacks. The editor
calls `menuBar.handleEvent(event)` before its own dispatch switch.

Queue mode (typing during agent execution) uses the same `InputRegion`
instead of an ad-hoc absolutely-positioned slot — the editor just sets
`screen.input.render(...)` with a `[N queued]` label, and `endCancelMonitor`
calls `screen.input.clear()`.

SIGWINCH: the app's signal handler calls `screen.resize(newLayout)` then
`editor.handleResize()`. The screen redraws the frame; the editor
re-renders the input row at its new bounds.

### Spinner / ProgressCounter

Take a `StatusRegion` and a relative row index. Write to that row; the
region clips and repairs borders. `Spinner` is a no-op today (the
turn-animation was retired); `ProgressCounter` still writes progress
text. They have no opinion on where on the screen they live — the host
decides by passing `region: screen.status, rowOffset: N`.

### Backend abstraction

`Screen` delegates all rendering to a `TerminalBackend`. The backend
interface is batched: callers build up a sequence of
`moveCursor` / `eraseCells` / `writeText` calls, then `flush` sends
them to the terminal. This lets ANSI backends emit one batched string
and notcurses backends call `render()` once.

Two implementations exist:

- **`AnsiBackend`** — emits ANSI escape sequences. The default; works
  everywhere a terminal emulator speaks VT100.
- **`NotcursesBackend`** — delegates to the notcurses C library via
  `dart_notcurses`. Gets genuine ncplane-based z-ordering, cheap
  move / resize, and the notcurses rendering pipeline. Selected at
  startup when `isNotcursesAvailable()` returns `true` (safe FFI probe
  that never throws).

A parallel `InputBackend` abstraction decouples `LineEditor` from the
raw byte stream:

- **`AnsiInputBackend`** — wraps `Stdio.stdin` through `InputParser`.
- **`NotcursesInputBackend`** — wraps native key events from the
  notcurses event loop.

Both expose a `Stream<InputEvent>` and an `inject(event)` method for
synthetic events (signal handlers, menu callbacks).

`BackendFactory` is a typedef that lets consumers supply a custom
backend to `Screen.withBackend`. `BackendSurface` (see Panels below)
is the plane-handle counterpart — an opaque drawable area that routes
through the same backend sink.

### MenuBar

`MenuBar` implements `Focusable` and renders desktop-style menu labels
on the top row of the terminal. Owns an `OverlayRegion` for the dropdown
panel. Routes arrow keys, Enter, and Esc when active; the editor calls
`menuBar.handleEvent(event)` before its own dispatch. Menus are defined
via `Menu` / `MenuItem` / `MenuSeparator` value types in `menu.dart`.
Alt-key shortcuts (e.g. Alt+F for "File") activate menus directly.

### InfoPanel

Passive content panel for the right-hand info box (the `info` region in
split layout). `InfoPanel` implements `Focusable` so `FocusManager` can
steer Ctrl+Arrow navigation to and from it. Has no border of its own
(would double up with the frame) and no scroll or cursor state — it's
a passive info surface.

### ToolChip

`ToolChip` holds the UI state for a single tool invocation in the tool
strip: tool name, tool id, state (`running` / `success` / `error`), and
an output buffer. One chip exists per in-flight or recently-finished
tool call. The strip renders them left-to-right; a future output panel
will show the `outputBuffer` of the focused chip.

### Panels & focus

The toolkit has a second axis beyond Regions: **Panels** — areas that are
both *rendered* (like a Region) and *focusable* (they receive keyboard input
when active). This is the seam a file browser, a help sidebar, or any future
tiled/floating UI is meant to build on. It is also where tina's previous
"no focus abstraction — each modal carries its own `_active` bool" gap got
closed.

- **`BackendSurface`** (`src/backend/backend_surface.dart`) — the
  backend-side counterpart to Region. An opaque handle to an independent
  drawable area: `putAt`/`eraseAt` at *relative* coords, plus
  `moveTo`/`resize`/`raiseToTop`/`lowerToBottom`/`destroy`. The notcurses
  backend backs it with a real child `ncplane` (genuine z-ordering and cheap
  move/resize); the ANSI backend emulates it as a rect offset over the shared
  batched buffer (writes stay absolute — Screen already clips).
  `Screen.createSurface(bounds)` is the factory; passthrough mode returns a
  degenerate surface that writes straight to stdout. Visibility is *not* on
  this interface — notcurses has no native hide/show, so show/hide is handled
  one layer up (the Panel retains its rows and re-emits/erases them), which
  is why it works identically on both backends.
- **`Focusable`** (`src/focusable.dart`) — `hasFocus` / `canFocus` /
  `focus()` / `blur()` / `handleEvent(InputEvent) → bool`. The contract any
  focus-receiving component implements. `MenuBar`, `InfoPanel`, `Panel`,
  and `ChatRegion` implement it; `CompletionPicker` and `ConfirmDialog`
  still carry their own `_active` flags (candidates to migrate later).
- **`Panel`** (`src/panel.dart`) — `abstract class Panel extends Region
  implements Focusable`. Owns its `Rect` and a `BackendSurface`, retains a
  row buffer (so show/hide, move, and resize all preserve content), and
  exposes `mount`/`unmount`/`show`/`hide`/`moveTo`/`resize`. Subclasses fill
  `rows` and implement `handleEvent`; they inherit clipping and surface
  lifecycle for free.
- **`FocusManager`** (`src/focus_manager.dart`) — the focus ring. Holds an
  ordered list of `Focusable`s, tracks the focused one, and dispatches:
  **Ctrl+W** toggles the ring (enter from the host, exit back to it),
  **Tab** cycles while a panel is focused, **Esc** also returns focus to
  the host. Ctrl+W (byte `0x17`) is picked as the entry key because
  F-keys like F8 default to media keys on Apple keyboards. Two known
  collisions to be aware of: readline's delete-word-backward muscle
  memory (harmless inside tina since the editor doesn't bind it, but
  potentially confusing), and VSCode / JetBrains integrated terminals
  intercepting it as close-tab before the process sees the byte — Esc
  is the reliable escape hatch in that case. It is wired into
  `LineEditor._dispatchEvent` *underneath* the existing modal layer (menu
  bar / picker / dialog still preempt), so panels are additive — the
  editor's dispatch switch is unchanged.
- **`TextPanel`** (`src/text_panel.dart`) — a minimal framed panel that
  demonstrates the seam: a titled box, focus-driven border styling, and
  Up/Down cursor navigation while focused. Not a file viewer — a reference
  implementation and a test target.

The invariant these preserve: a Panel never emits ANSI directly. Its only
output path is its `BackendSurface` (which routes through the same backend
sink as everything else), so "borders can't be eaten" and "writes can't
leak past the panel" hold for panels exactly as they do for Regions.

## Inside `packages/tina_index/`

An AST-derived code dependency graph for Dart codebases. The package
has no agent / LLM dependencies — it's a pure analysis library.

```
packages/tina_index/
  lib/
    tina_index.dart    — barrel: exports everything below
    symbol.dart          — Symbol + SymbolKind (function, class, method, field …)
    edge.dart            — Edge + EdgeKind (extends, implements, imports, contains …)
    symbol_table.dart    — qualified-name-indexed symbol lookup
    graph.dart           — CodeGraph: bidirectional edge lookup container
    graph_builder.dart   — extract structural and import edges from parsed files
    extractor.dart       — SymbolExtractor: parse Dart files → symbols
    walker.dart          — DartFileWalker: discover .dart files in a repo
    store.dart           — GraphStore: serialize / deserialize graph to disk
    traversal.dart       — GraphTraversal: expand seed symbols through the graph
    seeding.dart         — seedQuery: keyword-based symbol matching
    hasher.dart          — content hashing for incremental rebuild detection
    fuzzy.dart           — fuzzy symbol-name scoring
  test/
    extractor_test.dart, graph_test.dart, seeding_test.dart,
    store_test.dart, symbol_table_test.dart, traversal_test.dart,
    walker_test.dart
```

The pipeline: `DartFileWalker` discovers `.dart` files → `SymbolExtractor`
parses each into `Symbol`s → `GraphBuilder` adds `Edge`s (extends,
implements, imports, contains) → `CodeGraph` holds everything with
bidirectional edge lookup. `GraphStore` persists to disk with content
hashes (`Hasher`) for incremental rebuild. `GraphTraversal` expands seed
symbols outward; `seedQuery` matches keywords to entry points.

The app consumes this via `SearchTool` (graph search) and
`SummaryGenerator` (LLM-driven summarization of stale symbols).

## Inside `packages/dart_notcurses/`

Dart FFI bindings to the [notcurses](https://notcurses.com/) C library.
Ships pre-built native libraries for macOS arm64.

```
packages/dart_notcurses/
  lib/
    dart_notcurses.dart  — barrel
    src/
      notcurses.dart     — Notcurses: top-level init / teardown
      plane.dart         — Plane: drawable surface (child planes, z-order)
      cell.dart          — Cell: styled character
      channels.dart      — Channels: foreground / background color pair
      direct.dart        — Direct: line-buffered (non-alt-screen) mode
      visual.dart        — Visual: image / video rendering
      menu.dart          — Menu: native menu widget
      reader.dart        — Reader: text input widget
      key.dart           — key-code constants (NCKEY_*)
      shared.dart        — shared helpers
      plot.dart          — Plot: numeric plot widget
      ptypes.dart        — pixel-geometry types
      ffi/               — generated FFI bindings (ffigen)
  native/                — pre-built .dylib / .so
  hook/                  — native_assets build + link hooks
  examples/              — ported notcurses examples
  test/                  — FFI smoke tests, cell / channel / plane / lifecycle
```

The package is a thin wrapper — it exposes the C API in idiomatic Dart
without imposing a widget layer. `tina_console`'s `NotcursesBackend`
and `NotcursesInputBackend` are the consumers; nothing else in the repo
imports `dart_notcurses` directly.

## A single turn, end to end

1. User types `> implement X @lib/foo.dart` at the prompt.
2. `LineEditor.readLine` returns the input. The `@` opened the picker,
   the selected path was inserted, then Enter submitted.
3. `Repl.run` checks for a slash command; falls through.
4. REPL begins an ESC cancel monitor on the editor, calls
   `agent.run(system, history, userInput)`.
5. `Agent.run` appends a user `Message`, opens a stream via
   `provider.send(...)`, and routes events through the `AgentSink`:
   - `TextDelta`s → `sink.text(...)`,
   - `ToolCallStart`s → `sink.toolStart(...)` (renders `→ toolname`
     on the chat panel via `ChatAgentSink`),
   - waits for `MessageComplete`.
6. If the assistant message includes `ToolUseBlock`s, `Agent` walks each
   one through `PermissionPolicy.check`. If the result is `ask`, it calls
   the `PermissionAsker` (raw-mode Y/N/A/D in interactive mode). Allowed
   tools execute; results become `ToolResultBlock`s appended as a user
   message; the loop iterates.
7. When the assistant produces no tool calls, the loop exits and prints
   token usage.
8. REPL takes the new tail of `history` (everything appended since the
   pre-turn length) and writes each `Message` to the `SessionRecorder`.
9. Back to the read prompt.

Cancellation (ESC) cuts in at step 5/6: the cancel completer fires, the
stream subscription is closed, and the agent prints `[cancelled]` and
returns.

## Tests

Tests follow the source structure: each layer has its own folder.

- `packages/tina_engine/test/` — the engine's own suites, mirroring its
  layout: `agent/` (output interface contracts, stream assembly +
  cancellation, environment block, token budgets, sub-agent scheduling),
  `llm/` (wire-format adapters, retry / timeout), `tools/` (per-tool
  schema, validation, execution), `permissions/`, `persistence/`,
  plus `agent_event_bus_test.dart` at the root.
- `test/` (root, the app) — mirrors `lib/`: `config/`, `completion/`,
  `composition/`, `host/`, `llm/` (config-driven provider tests),
  `permissions/`, `persistence/`, `pipeline/` (workflow supervisor,
  default workflow), `platform/`, `project/`, `regions/`, 
  `session_commands/`, `summaries/`, `tools/`, `tui/`, and the top-level
  suites (`session_test.dart`, `session_controller_test.dart`,
  `session_manager_test.dart`, `conversation_test.dart`,
  `message_queue_test.dart`, `tui_coordinator_test.dart`,
  `import_boundary_test.dart`, `default_workflow_test.dart`,
  `feature2_multi_session_test.dart`, `workflow_supervisor_test.dart`).
- `test/helpers/` — `fake_agent_sink.dart`, `fake_stdio.dart` — shared
  test infrastructure.
- `packages/tina_console/test/` — split by component:
  - `screen_layout_test.dart`, `screen_test.dart`,
    `screen_backend_lifecycle_test.dart` — pure layout math, clipping
    primitives, and backend lifecycle.
  - `region_chat_test.dart`, `region_status_test.dart`,
    `region_input_test.dart`, `region_overlay_test.dart` — one per region
    type, covering clipping, scrolling, cursor positioning, border repair.
  - `spinner_test.dart`, `confirm_dialog_test.dart`,
    `completion_picker_test.dart`, `menu_bar_test.dart` — overlay
    behaviour and menu dispatch.
  - `line_editor_test.dart`, `line_editor_input_backend_test.dart` — full
    keystroke → buffer dispatch, including picker, dialog, queue mode,
    split-mode rendering, and InputBackend integration.
  - `backend_contract_test.dart`, `backend_factory_test.dart`,
    `input_backend_test.dart`, `ansi_input_backend_lifecycle_test.dart` —
    TerminalBackend / InputBackend interface contracts.
  - `notcurses_backend_test.dart`, `notcurses_backend_platform_test.dart`,
    `notcurses_backend_visible_columns_test.dart`,
    `notcurses_translate_key_test.dart` — notcurses backend specifics.
  - `render_pipeline_test.dart` — end-to-end *invariants* against a
    `VirtualTerminal`: frame intact through chat scroll, spinner, picker
    open/close, dialog show/hide, SIGWINCH resize, Ctrl-U on wrapped
    buffer. This is the regression net that catches "border got eaten"
    and "text leaked past divider" bugs the architecture is designed to
    prevent.
  - `line_edit_test.dart`, `line_layout_test.dart`, `fuzzy_test.dart`,
    `input_parser_test.dart`, `ansi_capable_test.dart` — pure-data units.
  - `panel_test.dart`, `focus_manager_test.dart` — Panel render/show-hide/
    focus and FocusManager ring logic (ANSI backend + `VirtualTerminal`;
    FocusManager is tested with plain fakes).
- `packages/tina_index/test/` — `extractor_test.dart`, `graph_test.dart`,
  `seeding_test.dart`, `store_test.dart`, `symbol_table_test.dart`,
  `traversal_test.dart`, `walker_test.dart`.

The full pipeline is exercised through `FakeStdio` (records output, lets
tests inject bytes) plus `VirtualTerminal` (an in-memory 2D character
grid that interprets the ANSI sequences the screen emits). Together they
turn every render-path test into a verifiable assertion about the final
on-screen state — without a real TTY.

## Why these boundaries

A few decisions are load-bearing and worth making explicit:

- **Provider-neutral message model with thin adapters.** The agent loop,
  tools, REPL, and persistence all think in `Message` + `ContentBlock`.
  The two adapters translate to/from wire format. This is the single
  decision that makes "support both Anthropic and OpenAI" cheap, and it
  doubled as the persistence format (we just write the JSON we already
  have).
- **The agent is reusable.** Both the interactive REPL and the
  non-interactive `--prompt` path call `Agent.run` directly. Nothing
  about the agent assumes a human is at the keyboard — the
  `PermissionAsker` is just a function, and the `AgentSink` can be a
  `ChatAgentSink` rendering to a chat panel or a passthrough that
  writes plain text to stdout.
- **AgentSink decouples agent from UI.** The agent says *what happened*
  (text delta, tool start, tool output, tool complete, notice); the sink
  decides *how to render it*. The agent layer never imports a UI type —
  `AgentSink` lives in `tina_engine`'s agent layer and references only `Tool` from the
  tools layer. This is what will let the tool strip swap in a composing
  sink that routes tool events away from chat without the agent knowing.
- **Permissions are a layer, not a tool flag.** Tools don't know about
  permissions; the agent gates every `execute` through the policy.
  Defaults, CLI rules, and session memory compose in a fixed precedence
  (session > static > defaults). Adding a tool doesn't require touching
  permission code.
- **Persistence is an interface.** `SessionStore` lets us swap JSONL for
  SQLite or a remote backend without touching the REPL. `SessionRecorder`
  holds the active session id so the store interface stays stateless.
- **Session / Conversation model.** A `Session` carries account context
  (provider, API key, base URL); each `Conversation` within it owns its
  own agent, provider, history, permission policy, and chat region.
  Today every session has exactly one conversation, but this container
  is the seam that lets a session grow several — each with differing
  tools, models, and permissions.
- **The console toolkit is a separate package.** Forces the boundary to
  be a barrel + a couple of interfaces (`CompletionProvider`). The
  package has no agent/LLM dependencies and could be lifted into another
  Dart CLI as-is. The layout math being I/O-free is what makes any of it
  testable.
- **Backend abstraction.** `Screen` delegates all rendering to a
  `TerminalBackend` — ANSI escapes or notcurses — behind a batched
  interface (`moveCursor` / `eraseCells` / `writeText` / `flush`). The
  same `Screen`, `Region`, and `Panel` code runs against either backend.
  The notcurses backend is selected at startup via a safe FFI probe; if
  the library isn't available, ANSI is the fallback. A parallel
  `InputBackend` abstraction decouples the editor from the byte source.
- **One sink, one cursor model, one layout.** Every byte to stdout
  passes through `Screen` → `TerminalBackend`. Cursor position is
  computed inside the screen; nothing else tracks it. `ScreenLayout` is
  a single value object held by `Screen`; regions reference it via
  `screen.layout`. The previous architecture spread all three across
  `Renderer`, `PanelRenderer`, `SplitFrame`, `ScreenContext`, the
  editor's `_lastCursorRow` / `_lastTotalRows` trackers, and direct
  `stdout.write` calls in the REPL — and the recurring rendering bugs
  came from those drifting out of sync. Consolidating them is what made
  "borders can't be eaten" and "writes can't leak past their region"
  enforceable in code rather than enforced by convention.
- **Regions clip on every write.** A `Region` cannot, by construction,
  emit ANSI directly or position the cursor — its only output path is
  `screen.putAtAbsolute(...)`, which clips text to the region's width
  and re-emits border cells on the touched row. Adding a new overlay
  type means writing one subclass; you get clipping and border repair
  for free.
- **The completion source is supplied by the app.** The package owns
  the picker UI; the app owns the git-aware file enumeration.
  `tina_console` doesn't know about files or git — it knows about
  strings and ranking.

## What's deliberately not abstracted

A few things look like they could be interfaces and aren't:

- **`Screen` and the region classes** are concrete, not interfaces.
  There's one implementation; `Screen.passthrough(...)` covers the only
  realistic second mode (non-TTY). The rendering backend *is* abstracted
  (`TerminalBackend`) because there are genuinely two implementations
  (ANSI / notcurses) — but `Screen` itself isn't.
- **`Tool`** has a fixed set of built-in implementations and no plugin
  loader. Adding tools is a code change, not a config change. The agent
  loop is the simpler for it.
- **`Agent`** is concrete. The non-interactive path uses the same class
  with a different `PermissionAsker` and a passthrough `AgentSink`.
  Output is abstracted (via `AgentSink`); the loop itself isn't.
- **The line editor's keymap** is hardcoded. No keybinding config; one
  consumer.

The general rule: if there's exactly one implementation and no expected
second, the abstraction is the boundary itself, not an interface.
