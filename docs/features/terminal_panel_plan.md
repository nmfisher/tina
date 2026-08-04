# Interactive terminal-in-a-panel (Unix MVP)

## Context

`tina` runs subprocesses (bash/grep/…) only via **piped** `Process.start` — no TTY — so interactive programs (a shell with line editing, `vim`, `htop`, `less`) can't run inside the TUI. The panel system, focus manager, and input-routing pipeline already exist and are reusable. The two missing pieces are (1) a real PTY and (2) a VT100/ANSI cell-grid emulator. This plan adds both, **Unix/macOS only**, and wires them into a new `TerminalPanel`. ConPTY slots in later behind the same `PtyConnection` interface.

Decisions locked with the user: **own the stack** (extend the in-tree emulator stub + hand-roll a Unix FFI PTY; no pub packages), **Unix/macOS only**.

Verified facts that shape the design:
- No PTY bindings exist anywhere (grep empty). Greenfield.
- `tina_console` and `tina_engine` are **sibling** packages (neither depends on the other); `test/import_boundary_test.dart` forbids the engine from importing either TUI package. A pure-`dart:ffi` PTY is allowed in the engine; the emulator/panel belong in the console.
- Two in-tree emulator stubs exist. The better one is `packages/tina_console/test/virtual_terminal.dart` (cell grid, save/restore, CSI `H/G/J/K/X/A/B/C/D/m/h/l` + SS3) — but its `_Cell` is **bare** (`{String char}`; SGR `m` discarded), and it lacks scroll-on-overflow, scroll region, alt screen, ins/del, OSC, charset, mouse. `tool/visual_test.dart`'s stub is cruder *and* that tool is already broken (imports a nonexistent `panel_renderer.dart`).
- `InputEvent` is **semantic only** (no general raw-byte event). Forwarding keys to a PTY needs an `InputEvent → xterm-bytes` encoder, not a tap on `TerminalBackend.stdin` (which is global — would steal all input).
- Rendering: `Panel._emitRow` (`packages/tina_console/lib/src/panel.dart:150`) writes `rows[r]` verbatim. Both backends apply per-cell attrs to SGR-tagged text — notcurses parses embedded SGR via `_emitSgrStyled` (`backend/notcurses_backend.dart:686+`); ANSI passes it through. So emitting SGR-tagged row strings "just works" on both.

## Placement

- **PTY (UI-agnostic)** → new `packages/tina_engine/lib/src/tools/pty_runner.dart`, next to `process_runner.dart`. Pure `dart:ffi` libc lookup via `DynamicLibrary.process().lookupFunction` (precedent: `fdopen`/`clock_gettime` at `packages/dart_notcurses/lib/src/notcurses.dart:148-178`). **No build hook, no vendored C.** Add `platforms: {linux, macos}` to `packages/tina_engine/pubspec.yaml` (first explicit platform block in the repo). Reusable by `bash_tool` later.
- **Emulator + encoder + `TerminalPanel`** → `packages/tina_console/lib/src/terminal/` (`emulator.dart`, `input_encoder.dart`) and `packages/tina_console/lib/src/terminal_panel.dart`.
- **Wiring + open command** → root app (`lib/tui_coordinator.dart`).

## Components

### 1. Emulator — promote + extend (biggest slice; everything depends on it)
Move `packages/tina_console/test/virtual_terminal.dart`'s core to `lib/src/terminal/emulator.dart` as `TerminalEmulator`; keep the test assertions in `test/` as a thin helper over the lib type's public grid. Extend:
- **Cell attributes**: `Cell { String char; CellStyle style; }` carrying fg/bg (default + 8/16-color + **256-color** `38;5;N`/`48;5;N` + truecolor `38;2;r;g;b`/`48;2;r;g;b`) and bold/italic/underline/reverse. SGR `m` mutates a current-style cursor (mirror xterm: parameter parsing, `0` reset, `39`/`49` default, semicolon chains).
- **Scroll-on-overflow**: `\n`/index past the bottom row scrolls the scroll region up by one (default region = full screen); new blank row at bottom.
- **Scroll region** DECSTBM (`CSI r`), **alt screen** (`?1047h/l`, `?1049h/l`) as a second grid + saved cursor, **real save/restore** (ESC 7/8 — currently dropped), **cursor show/hide** (`?25h/l`).
- **DEC private-mode tracking** (state the encoder needs): DECCKM `?1h` (application cursor keys), keypad application `ESC =`/`ESC >`, bracketed paste `?2004h`, focus `?1004h`, and mouse modes `?1000/1002/1003/1006h` (tracked now; mouse *encoding* is deferred — see tmux note).
- **Missing CSI**: ins/del line (`L`/`M`), ins/del char (`@`/`P`), scroll up/down (`S`/`T`), index/ri (`ESC D`/`ESC M`), erase (`J` modes 0/1`, `K` modes 0/1/2), tab stops (`\t`, `CSI I`/`Z`).
- **OSC** (`ESC ]…BEL/ST`): strip title/color-set sequences; respond to device-attribute queries (`CSI c`, `CSI > c`) with a static xterm reply so ncurses apps don't block on startup.
- **Grid → SGR row renderer**: `String rowToSgr(int r)` emitting `\x1b[…m` runs only on attribute changes (cheap), consumed by `TerminalPanel`.
- Defer (note as MVP gaps): charset switching (G0/G1), mouse tracking, wide/combining-char widths.

### 2. PTY runner — `packages/tina_engine/lib/src/tools/pty_runner.dart`
- Use **`forkpty(3)`** (one libc call: openpty + fork + setsid + `TIOCSCTTY` + dup2). Prefer this over hand-assembling `posix_openpt`/`grantpt`/… because **`grantpt` is not async-signal-safe** — unsafe to call between `fork` and `exec` in the Dart VM's threaded process; `forkpty` does all pty setup in the parent and only async-signal-safe calls (`setsid`/`ioctl`/`dup2`/`execvp`) in the child. Resolve via `DynamicLibrary.process().lookupFunction`; document the hand-assembled `posix_openpt` path as the fallback if `forkpty` doesn't resolve on some Linux.
- **The hard kernel**: the master fd is a raw int — `dart:io` exposes no fd reads. Run a **dedicated read isolate** that loops FFI `read(masterFd, buf, n)` and forwards `List<int>` chunks over a `SendPort` → exposed as `Stream<List<int>> output`. Writes go via FFI `write(masterFd, …)`. `exitCode` from FFI `waitpid`; `kill()` sends `SIGTERM` (matches the existing `kill()` contract). Register the pid with `ChildProcessRegistry.instance.track/untrack` (mirror `_IoRunningProcess`, `process_runner.dart:102-117`).
- API: `class PtyConnection { Stream<List<int>> get output; void write(List<int>); void resize(int rows, int cols); Future<int> get exitCode; int get pid; void kill(); }` + `PtyRunner.spawn(executable, args, {workingDirectory, environment, rows, cols})`. Default shell `$SHELL` else `/bin/sh`. `resize()` uses `ioctl(masterFd, TIOCSWINSZ, &winsize)` — the kernel auto-delivers **SIGWINCH** to the child's foreground group, which is what tmux/ncurses redraw on. Set `TERM=xterm-256color` + `COLORTERM=truecolor` in the child env.
- Note the **`RunningProcess` interface doesn't model this** (separate stdout/stderr, no stdin) — `PtyConnection` is a *parallel* type, not a subtype. Don't bend `RunningProcess` to fit.

### 3. InputEncoder — `packages/tina_console/lib/src/terminal/input_encoder.dart`
`List<int> encodeForPty(InputEvent e, {required TerminalModes modes})` over the closed `InputEvent` set: `CharInput`→UTF-8; `ControlKey(enter)`→`\r`, `(tab)`→`\t`, `(backspace)`→`\x7f`, `(ctrlC)`→`\x03`, etc.; `ArrowKey`→`\x1bOA` if `modes.decckm` else `\x1b[A` (plus `\x1b[1;5A` ctrl-variants); `EditingKey`→Home/End/Delete xterm sequences; `FunctionKey`→`\x1bOP`…; `AltKey`→`\x1b<letter>`; `EscapeKey`→`\x1b`; `PasteInput.text`→wrapped in `\x1b[200~…\x1b[201~` when `modes.bracketedPaste` else verbatim; `UnknownEscape.bytes`→verbatim. The `modes` come from the emulator's tracked DEC private states. Additive — no `InputEvent`/`InputParser` changes. **tmux needs** DECCKM + bracketed-paste honoring; both are in. Deferred: mouse-event encoding (no `MouseEvent` in the hierarchy today).

### 4. TerminalPanel — `packages/tina_console/lib/src/terminal_panel.dart`
`class TerminalPanel extends Panel` (reuses `mount`/`unmount`/`resize`/`redraw`/`raiseToTop`/`handleResize`; gets a real `BackendSurface` with z-order).
- Holds `TerminalEmulator` + `PtyConnection`.
- `mount()`: `super.mount()`; spawn PTY at interior size; subscribe `pty.output` → `emulator.feedBytes` → `redraw()` (debounced via `screen.frame`).
- `render()` override: drain `emulator.rowToSgr(r)` into `rows[r]` (respect border interior — leave the panel's own frame drawn by base), then `super.redraw()`.
- `handleEvent(InputEvent e)`: if focused, `pty.write(encodeForPty(e))`; return `true` (consume) — bypasses the shared `LineEditor` while focused (this is the spawn-unification "one shared input line" model being intentionally set aside for the terminal). `FocusManager`'s cycling keys (Ctrl+W/G) are intercepted *before* the focused panel (`line_editor.dart:458-468`), so the user can always cycle out.
- `handleResize()` override: recompute interior cols/rows → `emulator.resize()` + `pty.resize(rows, cols)` → `render()`.
- Chrome: reuse `theme.border.focus`/`.selection` for the frame like `TextPanel` (`text_panel.dart:60-63`); content colors come from the child's SGR, not `Theme`.

### 5. Coordinator wiring — `lib/tui_coordinator.dart`
- Add a `/term` command (mirror `/branch`) that creates a `TerminalPanel`, assigns it a rect via a new branch in `_layoutPanels` (`tui_coordinator.dart:690-743` — currently ConversationPanel-only), `mount()`s it, and `focusManager.register` + `focusPanel`.
- SIGWINCH handler (`tui_coordinator.dart:1470-1489`): after `_layoutPanels()`, the panel's `handleResize()` propagates cols/rows to emulator + PTY. Ensure `bounds` is accurate (spatial nav `FocusManager._nearestInDirection` depends on it, `focus_manager.dart:221-275`).

## tmux compatibility

`tmux` is just a child process in the PTY — the architecture supports it. The emulator/encoder items above (alt screen, scroll region, 256-color + truecolor, DECCKM, keypad, bracketed paste, focus tracking, `TIOCSWINSZ` resize, `TERM=xterm-256color`) are exactly the feature set tmux leans on, so a keyboard-driven tmux session renders and resizes correctly. **Deferred to a follow-up: mouse.** tina's input pipeline has no mouse event today (`InputParser` doesn't parse mouse CSI `CSI <`/`M`; `InputEvent` has no `MouseEvent`), so tmux mouse pane-resize/select/scroll needs parser + event-hierarchy + encoder work — a separate slice. Note: running tmux inside a panel while tina itself runs inside an outer tmux is nested-multiplexing; setting `TERM=xterm-256color` for the child avoids the worst of it, but exotic key sequences may collide.

## Sequencing (lowest-risk first)

1. **Emulator** (slice 1) — pure Dart, no FFI, no TUI. Biggest chunk; everything depends on it. Ship + unit-test first.
2. **InputEncoder** (slice 3) — pure function, table-driven tests. Stacks on nothing.
3. **PTY runner** (slice 2) — FFI + read isolate; unit-test with a `MemoryPtyRunner` double, real-spawn `/bin/echo` behind a platform gate.
4. **TerminalPanel** (slice 4) — glue; headless test via `FakeStdio` + `Screen` + ANSI backend.
5. **Coordinator `/term` + resize** (slice 5) — manual verification.

Slices 1–3 are pure-Dart/engine and need **no** `dart_notcurses` submodule; slice 4–5 tests run on the ANSI backend without notcurses built.

## Verification

- **Emulator unit tests** — `packages/tina_console/test/terminal/emulator_test.dart`: feed synthetic CSI/SGR/scroll/wrap/alt-screen/OSC byte streams, assert grid + attrs + cursor. Pattern: `packages/tina_console/test/panel_test.dart` (`FakeStdio` from `packages/tina_console/test/stdio_fake.dart`).
- **Encoder unit tests** — table-driven over every `InputEvent` subtype; assert exact bytes.
- **PTY unit tests** — `packages/tina_engine/test/tools/pty_runner_test.dart`: `MemoryPtyRunner` mirroring `MemoryRunningProcess` (`hangUntilKilled: true`, exit 143); real-spawn group gated `Platform.isMacOS || Platform.isLinux` (`process_tree_test.dart:8` idiom), inline `.timeout(Duration(seconds: 5))`, assert `/bin/echo hi` round-trip + exit code + `resize()` no-crash.
- **Host-only integration test** — spawn a shell, drive `TerminalPanel` headless, assert echoed keystrokes round-trip and resize propagates. Guard with the `/dev/tty` probe copied from `packages/dart_notcurses/test/harness.dart:38-45` (**`stdout.hasTerminal` is false under `dart test`**); put behind a `dart_test.yaml` with `concurrency: 1` (parallel runners corrupt `/dev/tty`).
- **Manual** — open the terminal panel in the live TUI; confirm focus toggles, keystrokes reach the shell, `resize` (window resize) reflows, `vim`/`less` enter/exit alt screen cleanly.
- Run per-package: `dart test` (dev dep `test: ^1.25.0` already present). Assert from `TuiCoordinator.create()` output, not `run()`, for structure (`AnsiInputBackend` stream — `test/tui_coordinator_test.dart:283-288`). No latency assertions under `dart test` (FFI clock returns 0 — `input_latency_test.dart:120-124`).

## Notes

- `tool/visual_test.dart` is already broken (imports nonexistent `panel_renderer.dart`). Out of scope to fix, but promoting the test-grade emulator is the right extraction regardless.
- A worktree agent implementing slices 4–5 must `git submodule update --init packages/dart_notcurses` (shows untracked today) before anything notcurses-linked resolves; slices 1–3 don't need it.
