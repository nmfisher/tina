# Running Tina's TUI with the wasm backend — options and plan

Recorded 2026-11-09. Decision: **Option 1 proceeds now. Option 2 is a timeboxed
experiment in parallel. Option 3 is parked.** This document records the options,
the facts behind them, and the work plan.

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
