# Running Tina's TUI with the wasm backend — options and plan

Recorded 2026-11-09. Decision: **Option 1 proceeds now. Option 2 is a timeboxed
experiment in parallel. Option 3 is parked.** This document records the options,
the facts behind them, and the work plan.

**SDK note (updated 2026-11-12):** the wasm toolchain no longer rides an
experimental SDK. The Dart pin moved from the source-built edge
`3.14.0-edge.e7112ac…` to released **stable 3.14.0**
(`/home/agent/tools/dart-sdk-3.14.0-stable`), validated end to end: engine and
TUI components plus the entity-decode fixture rebuilt on stable, boot +
scripted-turn green on both engines, the wasm.dart component and parity suites
passing, and the wasm_tools patches the move needed landed upstream of the pin
(SIMD opcode-table widening, timeline-import DCE tolerance). The edge checkout
stays at `/home/agent/tools/dart-sdk-src` as a fallback only. Any earlier text
below that assumes an experimental/edge SDK is historical.

## Background

The wasm stack ships as one binary: `tina-wasm-host` with the Tina engine
component embedded. It speaks the pipes protocol and runs the full agent loop.
It has no TUI: a wasm component cannot own a terminal. The question is how the
terminal experience works on top of it.

Terminal facts (checked 2026-11-09, sources in the issue comments):

- WASI Preview 2/3 has terminal *resources* (stdin/stdout/stderr can be marked
  as terminals; wasmtime 47 implements the detection). It has no terminal
  *controls*: no raw mode, no echo/buffering toggles, no window size, no resize
  events.
- The proposal that would add those (wasi-cli PR #62: immediate input, echo
  control, window size, resize notifications) is closed unmerged after the
  monorepo migration. Tracking issue: WebAssembly/WASI#759. Do not wait for it.
- Whatever we choose, the host binary must own the real terminal: raw mode,
  window size, signals. A wasm component can only draw bytes.
- Terminal ownership is a trust boundary. Raw mode turns Ctrl-C into input
  bytes. A sandboxed guest can still emit spoofing escape sequences. TTY
  authority stays in trusted host/UI code. Never give plugins ambient TTY
  access.

## Option 1 — Native TUI front end, wasm engine backend (CHOSEN)

The terminal app stays native. The engine runs as wasm under wasmtime. They
talk over the pipes protocol.

- Cost: moderate. Risk: low. Matches the architecture the program already
  committed to (headless wasm engine + native front ends).
- The native TUI keeps everything it has today: rendering, resize, input.

### Work plan

Phase A — pipes completeness (tina repo, foundation for the front end):

1. Make `SessionConnection` an interface and add a pipes-backed implementation,
   so the TUI's engine calls do not require an in-process object.
2. Extend the pipes protocol to carry what the TUI consumes and currently
   loses: live chat previews, active-tool progress, general questions/notices,
   command and settings discovery. (The wire today carries only `ready`,
   `status`, `receipt`, `entry`, `cancel` and `approval` events; the rest of
   the in-process snapshot — feature projections like the chat preview,
   active tools, pending questions, notices — and the command vocabulary
   never cross it.)
3. Fix the per-chunk UTF-8 decoding bug and bound the outbound queue. (The
   engine's line decoder re-decodes each stdin chunk independently
   (`apps/tina_cli/lib/src/pipes.dart`, `_linesOf`), so a multi-byte
   character split across a chunk boundary throws and kills the session; the
   fix carries raw bytes to the line boundary and decodes whole lines.)
4. Validation: the existing scenario records must stay green (cancellation,
   approval grant/deny), plus new records for the added messages.

Phase B — TUI over pipes:

1. A launcher that spawns `tina-wasm-host` (or any engine backend), wires
   stdio, and hands the streams to the front end.
2. The TUI's engine calls route over pipes through the new connection.
3. Validation: a full interactive session driven through the wasm engine —
   turn, streaming, cancel, approval, reload via `/plugins` — with the native
   engine as parity reference. Resize stays native (frontend-only).

Phase C — dogfood and document.

## Option 2 — TUI inside the wasm sandbox, ANSI rendering (timeboxed experiment)

The TUI code compiles into the wasm component too, drawing with plain ANSI
escape codes. Tina's TUI already has an ANSI backend (`--backend=ansi`; tmux
users get it automatically), so **notcurses is not needed for this route**.

- The host binary owns raw mode, window size, and signals in the same process —
  the guest draws ANSI bytes through WASI stdout. Prior art proves the shape:
  the Terminal Games project runs wasm Ratatui/Bubble Tea apps under wasmtime
  on real terminals with exactly this contract.
- Timeboxed experiment, in a parallel lane, only after Phase A of Option 1:
  1. Make the ANSI backend's I/O portable (today `stdio.dart` and TUI startup
     import `dart:io`/FFI unconditionally — needs portable interfaces and
     conditional imports).
  2. Key input, resize handling, and clean terminal restoration after exit and
     after traps, host-side.
  3. Timebox: stop after the spike, report, decide.
- Not on the critical path.

## Option 3 — Port notcurses itself to wasm (parked)

Full graphics fidelity inside the sandbox. Not chosen, and not scheduled.

- The Dart glue that talks to notcurses goes through `dart:ffi`, which does not
  exist under wasm. The binding layer needs a rewrite regardless of what happens
  to the C library.
- The C library itself would need: compilation to wasm, its terminfo database
  embedded or preopened, and an answer for its pthread input loop. No verified
  port exists; upstream's Emscripten discussion does not provide one.
- Even the pending WASI terminal proposal would not remove the C port or the
  binding rewrite, and its draft normalizes escape sequences — it is not
  automatically transparent for notcurses.
- Trigger to revisit: the ANSI look is judged insufficient for the product, or
  a maintained notcurses-to-wasm port appears upstream.

## Sequencing

1. Now: Option 1 Phase A (pipes completeness) — foundation for everything.
2. Then: Option 1 Phase B (TUI over pipes) with Phase C dogfooding.
3. Parallel, after Phase A: Option 2 timeboxed spike on a separate branch.
4. Option 3: parked until its trigger fires.

## Phase B report — TUI over pipes (2026-11-09)

Landed on `codex/issue85-plugin-management` after Phase A (`16c0b60`,
`7c6e947`, `f2fe41a`, `c64539a`):

- **Launcher** (`apps/tina_cli/lib/src/engine_launcher.dart`):
  `EngineProcess` spawns any engine that speaks the pipes protocol on
  stdio — the packaged `tina-wasm-host`, a dev engine binary, or any
  command with the same contract — line-decodes its stdout with the
  Phase A byte-level decoder, and serves a `PipesConnection` over it.
  The launcher drains stdout for the process's whole life behind a
  broadcast controller: a front end that closes its connection must not
  leave the host dying on EPIPE while it writes its goodbye (observed as
  a broken-pipe panic, exit 101, before this).
  `wasmEngineArgv` translates CLI resources into the host convention —
  workspace and config tree as WASI preopens (`.`, `config`), engine
  knobs as `TINA_ENGINE_*` environment, provider endpoint and credential
  forwarded explicitly (`TINA_LLM_ENDPOINT`, `ANTHROPIC_API_KEY`) — so a
  sandboxed guest sees only what the launcher passes, never the host
  environment.
- **CLI surface**: `--engine native` (default, unchanged), `--engine
  wasm`, `--engine <path>`; `--engine-host` picks the wasm binary
  (`TINA_WASM_HOST`, then PATH); `--engine-arg` passes extra host
  arguments (whitespace-separated). `--engine` is interactive-only and
  conflicts with `--pipes`, session commands, `--configure`,
  `--import-sessions`, `--models`, `--dry-run` and `--model` (a remote
  engine takes its model from the config file; the wasm host convention
  has no model flag).
- **TUI routing** (`tui_remote.dart`, `session_view_remote.dart`):
  `RemoteTuiSession` implements the `TuiSessionHandle` contract `runTui`
  drives, so the renderer, input editor, resize and signal ownership are
  the same code as the native session. The view set is built from the
  connection alone (`connectionViewFor` in `console_catalog.dart` — the
  same mapping the native attachment path uses), driven by the engine's
  plugin list through snapshot updates, so plugin reloads keep the
  attached views in sync. The status strip is pure layout and always
  provided; approval asks render through `PipesApprovalView` (`y` allow
  once, `a` allow always, `n`/Esc deny) over the new approval surface.
- **Approval surface** (`pipes_connection.dart`): `approval` events
  become pending `ApprovalRequest`s, `respond` sends the `approve` op,
  `approval-result` retires the ask. The wire carries the decision only
  (allow / always / deny) — command patterns and directory grants stay
  engine-side. `ready` now also fixes the session id and model into the
  client status. One wire ordering hazard is fixed client-side: a
  receipt is written immediately while its carrying status event is
  queued, so work a running receipt names counts as cancellable until
  that receipt reaches a terminal state — otherwise a stale status made
  an escape cancel nothing.
- **Wasm engine** (`tina_wasm`): the registry gains `tina/chat-tui`
  (the same `ChatPlugin` definition the native catalog serves), so the
  live chat projection — token streaming previews, model, token spend —
  crosses the pipes protocol as `tina/chat-tui` feature projections in
  snapshot events. The engine component was rebuilt and re-embedded in
  the packaged host; the stage-5 exit test reruns green on both engines.

### Validation record

- **Interactive TUI through each engine**
  (`apps/tina_cli/test/remote_tui_session_test.dart`, one scenario per
  leg, real `runTui` over a spawned engine process and a scripted
  dual-wire provider): a streamed plain turn (chat preview carries
  tokens while the work runs; committed reply entry follows), an
  ask-mode write surfaced as an approval ask and allowed from the
  dialog's `y` (approval-result accepted; the file lands), a mid-stream
  cancel from Escape (cancel accepted, receipt cancelled, session
  idles), and a clean quit with the engine exiting 0.
  - native engine over pipes (`dart run bin/tina.dart --pipes`,
    OpenAI-compatible wire): **pass**.
  - wasm engine over pipes (packaged `tina-wasm-host`, embedded
    component, plugin artifact attached with
    `--plugin-grant=session.read-context`, Anthropic wire over WASI
    HTTP): **pass**, including `/plugins` status and `/plugins reload`
    (lease book and `reloaded` notices rendered through the wire).
- **Approval surface records**
  (`pipes_connection_approvals_test.dart`, in-process engine): ask-mode
  write → `approval` event → `approve` → approval-result accepted and
  the write lands; a second `respond` on the same ask is refused.
- Existing records stay green: `pipes_test`, `pipes_connection_test`,
  `pipes_protocol_test`; `tina_host` 107/107; `tina_tui` 52/52;
  `tina_chat_tui` 126/126; `tina_wasm` 19/19; the stage-5 exit test
  passes on both engines with the rebuilt component.
- Full `tina_cli` suite: 438 passed, 4 skipped, 14 failed — see below.

### Pre-existing failures (baseline, unrelated to this program)

The app suite has carried 13 failures since before Phase A. They were
verified against the baseline commit (`16c0b60` in a git worktree
during Phase A, re-verified at `c64539a` for this report — isolated
runs produce the identical failure set) and are unrelated to the pipes,
launcher and TUI work:

| file | count | failing tests |
| --- | --- | --- |
| `approval_grants_test.dart` | 3 | read grant persists only at session / workspace / global scope |
| `mode_policy_test.dart` | 5 | auto reviews network with execution: ALLOW / DENY / unreadable; auto reviews network even when execution already has a session grant; human Always skips repeat auto review of git refs outside the workspace |
| `panels_test.dart` | 4 | UI Always (shortcut / arrows and Enter) remembers the exact command (confined / network) on later turns, even after failure |
| `restart_terminal_test.dart` | 1 | default backend, ANSI fallback and status preserve resumed input |

A fourteenth failure appears only under full-suite load:
`restart_terminal_test.dart: missing restart pathname does not prevent
launch or resume input`. It passes in an isolated run in this tree and
in the baseline worktree alike (both verified 2026-11-09); it is a load
flake in the same file as the genuine baseline failure, not a
regression of this program.

### Remote-session limitations (deliberate, bounded by the protocol)

- One engine process is one session: child sessions and the
  panels/workspace path are unsupported (`spawn` throws; `runApp` only
  requests child sessions with a workspace).
- The settings entry is an honest stub: the `settings` op is discovery
  only, so the panel explains that remote engines serve settings
  discovery and a restart applies config changes.
- The theme is the front end's default variant; the wire carries no
  theme, and the working directory reads as `''`, so `@` file
  completion has no suggestions (the `git ls-files` source degrades to
  empty, never an error).
- Approval decisions cross as allow / always / deny; command patterns
  and directory grants stay engine-side.
- `--model` is a native-only selection; a remote engine takes its model
  from the config file.
- Tool paths in scripted scenarios differ per engine: the native engine
  resolves host paths, the wasm guest sees only preopens, so absolute
  host paths outside a preopen are not writable by the wasm engine.

## Outcome (Phases A and B, 2026-11-09)

Option 1 is landed end to end on `codex/issue85-plugin-management`:
Phase A made the pipes wire carry what the TUI consumes
(`16c0b60`..`c64539a`: byte-exact line decoding, bounded outbound
queue, front-end surface on the wire, `SessionConnection` as an
interface), and Phase B routes the terminal app through a spawned
engine (`7bdc78f`: `EngineProcess` launcher, `--engine
native|wasm|<path>`, remote TUI session and approval dialog, the wasm
registry's `tina/chat-tui` live-preview projection). The full
interactive scenario — streamed turn, approval grant, mid-stream
cancel, `/plugins` reload, clean quit — passes through the TUI on both
engines; the packaged host (`89498ac0…`) and engine component
(`dd2b2cf…`) are unchanged since Phase B.

## Phase C report — dogfood over the wasm engine (2026-11-09)

A human-shaped dogfood pass: the terminal app driven by hand in a real
pty (tmux, ANSI backend) over `tina --engine wasm` with the packaged
host, against a scripted Anthropic-wire provider, in a scratch
workspace. Two sessions, both ending with the engine exiting 0.

### What was exercised

- **Session 1** — a plain turn that asks for a note file: the streamed
  preview and tool receipt render through the wire; the ask-mode write
  raises the approval dialog (`y` allow once); the file lands on disk
  with the requested content; the final reply streams in. A second
  slow turn cancelled mid-stream with Escape (`cancelled: escape`,
  strip back to idle, no stray provider writes).
- **Reload with a rebuilt artifact** — the prompt-plugin fixture was
  rebuilt twice from source through the pinned-SDK fixture pipeline
  (v1: unmodified source, `b60a5ab7…`; v2: same plugin with a
  `dogfood=v2` marker appended to its prompt-section output,
  `7d7590e0…`). The session started attached to v1 (`/plugins` shows
  `open`, lease `tina-plugin-lease-1-2`, `reloads=0`); the artifact
  file was then replaced with v2 and `/plugins reload` attached a
  fresh store (lease `…-1-3`, `reloads=1`). The proof that the *new*
  artifact was adopted lives on the provider wire: the plugin's
  prompt section reached the model request with the v1 store's run
  counter (`run=1`, then `run=2`, `run=3` across the session's turns)
  and, after the reload, with `run=1;dogfood=v2` — fresh plugin state
  and the rebuilt component in one observable.
- **Session 2** — a fresh process over the same workspace: the
  rebuilt artifact attaches cold, a turn streams, quit exits 0.
- **Startup cost** — 19 s from `dart run bin/tina.dart --engine wasm`
  to an interactive prompt (dart run build hooks, engine spawn,
  component instantiation, plugin compile-on-load, TUI init). The
  packaged host is a release binary; most of the wait is the CLI's
  own `dart run` tax, which a compiled binary removes.

### Rough edges found (all cosmetic or parsing, none blocking)

1. `--engine-arg` rejects a space-separated value that starts with
   `--` ("incomplete argument: --engine-arg requires ARGS") — which is
   exactly the form the option's own help text suggests. The
   `--engine-arg='--plugin-component=…'` form parses. A parser fix
   (accept the next token as the value) is queued under next steps.
2. Each launch prints the Dart build-hook line (`Running build
   hooks...`) to stderr twice before the TUI starts. Noise, not a
   fault; also disappears with a compiled binary.
3. The approval dialog names the tool and path only (decision-only
   surface, as designed — see the limitations above). Reading the
   full diff before deciding is a next-steps item, not a Phase C gap.

Everything else behaved as designed: the status strip identity
(session id, model, token spend), the chat preview, the receipt
states (`running` → `ok`), the cancellation message, the lease book
and reload counters, and clean engine shutdown on quit.

### Known next steps

- Fix the `--engine-arg` value parsing; align its help example.
- Ship a compiled CLI binary as the recommended dogfood path and
  re-measure startup without the `dart run` tax.
- Child sessions over one engine process (the protocol carries one
  session today), a settings surface beyond discovery, theme and
  `@`-completion sources over the wire, richer approval payloads
  (command pattern, directory grant, diff preview), and `--model`
  for remote engines.
- Option 2 (TUI inside the sandbox, ANSI) stays a timeboxed spike on
  a separate branch, awaiting the go.

## Option 2 outcome: productionized — the full TUI ships in the sandbox (2026-11-11)

The principal's go turned this round's timeboxed spike into the shipped
path. Production report: `docs/option2-wasm-tui.md` (tina
`codex/issue85-wasm-tui`) and its wasm.dart mirror. Round summary:

- Bare `tina-wasm-host` boots the FULL tina TUI (real `SessionAssembly`,
  `runApp`, `AnsiBackend`, `LineEditor`, status strip) from the embedded
  component; `--headless`/`--pipes` keeps the pipes protocol byte-for-byte
  for agents and scripts.
- Milestone-3 tmux matrix, all green on the branch tip: interactive
  parity (native `tina` vs the sandbox TUI, scripted keys: paint, typing
  echo, Ctrl-L, command palette, model picker, quit — structural byte
  comparison, not equality), resize 100x30→120x35 via the guest's 250 ms
  tty poll on both legs, clean quit (exit 0, balanced alt-screen
  enter/leave pairs), epoch kill (`TINA_TUI_EPOCH_TICKS`, exit 3 with the
  terminal restored — armed pre-boot and against a parked, already
  painted guest), and the failure channel (a guest config FormatException
  surfaces as `guest crashed: …; terminal restored`, exit 3, no parking).
- `/plugins` is not a session command on EITHER leg (the command registry
  carries no such command; plugin sessions still cross `tina:plugin-host`
  at boot) — the design doc's matrix item is satisfied by the registry's
  actual surface, noted as a deviation.
- Headless regression: the stage-5 exit test passes BOTH legs (native and
  wasm via `--headless` — the harness passes the new selector explicitly;
  the dispatch changed, the protocol did not).
- Suites at baselines: tina_console 1170, tina_tui 52, tina_chat_tui 126,
  fuzzy_ranker 11, tina_wasm 19, tina_capability 21, host crate 57,
  discovery_boot 4; the app-suite failure set is IDENTICAL to the merge
  base (the tip even fixes two headless tests that fail at the base).
- Host-side additions (wasm.dart `codex/issue85-wasm-tui`): wasmtime's
  compilation cache (the 4.8 MB guest recompiled on every bare boot),
  and the crash message is surfaced even when the exit-backstop trap wins
  the select race. The guest components rebuilt BYTE-IDENTICAL (engine =
  the ace8ca4 artifact; TUI = the milestone-2 embedded bytes).
