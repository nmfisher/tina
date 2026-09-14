# Interactive shell panel — implementation plan

Status: planned; panel foundation shipped in v0.6.19. Updated against v0.6.24
on 2026-09-14. This document replaces the earlier design at this same path.
Only the foundation is implemented; the phases below are future work.

## Outcome and scope

A user can open `/term`, type into a real interactive shell, switch back to a
conversation with Ctrl+G, and return without losing either the shell or the
chat draft. Shell line editing, completion, signals, and terminal applications
must work inside the panel on Linux and macOS.

The first release targets Linux x64/arm64 and macOS arm64. Windows/ConPTY,
reattaching shells after tina exits, agent access to terminal input/output,
mouse reporting to child applications, and complete xterm compatibility are
outside this release. A shell panel is a user-operated terminal; opening one
does not add an agent tool or bypass the existing bash/exec approval policy.

Retain the earlier preference for an in-tree implementation without third-party
terminal packages. The former requirement for pure Dart FFI with no native
shim is replaced by the native boundary described below. Do not advertise
`TERM=xterm-256color` or tmux compatibility until the relevant behavior passes
the compatibility checks.

## Foundation already present — reuse it

[Panel architecture](panel_architecture.md) is the source of truth for existing
panel behavior. Do not repeat this refactor or reintroduce conversation fixtures
for generic panel tests.

| Existing component | Responsibility to preserve |
| --- | --- |
| `lib/tui/panel_host.dart` | Opens arbitrary `PanelContent` with a `PanelSpec`; owns registration, frame, and synchronous view cleanup. |
| `packages/tina_console/lib/src/panel_content.dart` | Content geometry, borrowed surface, attach/detach, and repaint. |
| `lib/tui/conversation_panel_coordinator.dart` | Fits and parks extra content in tiled and sidebar layouts. |
| `packages/tina_console/lib/src/panel_input.dart` | `exclusive` input ownership; Ctrl+G is reserved for navigation. |
| `packages/tina_console/lib/src/line_editor.dart` | Routes exclusive input before chat editing/cancellation; prompts and modals take priority. |
| `lib/tui/run_panel_host.dart` | Example of a feature adapter using the generic host. Workflow stop/close semantics are not shell semantics. |

`PanelHost.openPanel` does not focus the new panel automatically. Its `onDispose`
is synchronous; it cannot own awaited process shutdown. Detaching/parking a
view is not closing its process. The shared editor already hides for exclusive
panels and preserves its draft when focus returns.

## Architecture and ownership

Use three independently testable layers. The engine and console remain sibling
packages; neither imports the other.

| Proposed component | Location | Owns |
| --- | --- | --- |
| `PtyRunner`, `PtyConnection`, Unix adapter | `packages/tina_engine/lib/src/terminal/` | Process launch, PTY byte I/O, dimensions, exit status, asynchronous termination. No screen or agent dependencies. |
| `TerminalEmulator`, input encoder, `TerminalPanelContent` | `packages/tina_console/lib/src/terminal/` | Terminal state, input conversion, and bounded rendering. No process creation or engine imports. |
| `TerminalPanelController` | `lib/tui/terminal_panel_controller.dart` | Connects the two layers, opens through `PanelHost`, manages focus and process lifetime. |
| `/term` integration | `lib/session_commands/` and application composition | Command registration/completion and a narrow UI capability to the controller. No FFI in command handlers. |

The console view takes terminal state and callbacks, not a `PtyConnection`.
The controller connects PTY output to the emulator and encoded input/query
replies to the PTY writer. Keep `RunningProcess` and ordinary `ProcessTool`
execution intact: separate stdout/stderr pipes are a different contract.
Do not declare the entire engine Linux/macOS-only; unsupported platforms must
still be able to import and use its nonterminal features.

Proposed PTY contract:

- `spawn` accepts resolved executable, literal argv, absolute working directory,
  a copied environment map, and positive rows/columns. It completes only after
  successful exec, or reports a structured launch failure.
- A connection exposes one ordered byte output stream, ordered asynchronous
  writes, resize, pid, exit status, and an idempotent awaited close operation.
- Distinguish child exit from completion of output draining. Preserve final
  output before showing exit status. Document normalized signal exit results.
- Inject the runner, process tracking, and scheduling/clock dependencies in
  tests. Fake connections must model pending spawn, partial output, blocked
  writes, exit, and close independently.

## Phase 1 — prove the native process boundary

Deliver a headless PTY backend before building the terminal UI.

Use a small in-tree native shim for launch, with the entire fork-to-exec child
path contained in native code. Prepare executable/argv/environment and other
allocations before fork; a child must never return through FFI into Dart,
allocate Dart objects, or invoke Dart callbacks. Keep child setup limited to
operations validated for that platform, then exec or `_exit` on failure.
The restriction follows the [fork documentation](https://man7.org/linux/man-pages/man2/fork.2.html):
a child of a multithreaded process may execute only async-signal-safe functions
until exec. A direct Dart call to `forkpty` followed by Dart-side child setup
does not satisfy that restriction.

Implement and document controlling-terminal setup, session/job-control behavior,
initial termios/window size, signal-mask/disposition reset, descriptor ownership,
close-on-exec, and exec-error reporting. Hide platform constants and libc symbol
resolution in the native adapter; do not copy Linux ioctl values onto macOS.
No raw blocking read, waitpid, or unbounded write may run on the UI isolate.
Use a worker with an explicit wakeup/shutdown mechanism, handle short writes,
EINTR/EAGAIN and platform EOF behavior, and reap exactly once. Bound queued I/O
and apply backpressure; do not silently drop terminal bytes.

The controller will await normal shutdown; integrate with `ChildProcessRegistry`
as a fallback. Specify how foreground jobs and remaining shell descendants are
terminated, with a bounded grace period and force termination. Killing only the
shell pid is insufficient. Deliberately detached external servers are not
promised to remain under terminal ownership.

Build the shim as a native asset independent of notcurses, including packaging,
macOS signing, and Linux architecture coverage. Verify both `dart run` and AOT
bundle loading. If the proposed native boundary cannot meet the launch and
shutdown checks, revise this phase before implementing later integration.

Acceptance:

- On Linux and macOS, the child reports terminal stdin/stdout/stderr, receives
  the requested cwd/environment, and produces output and exit status.
- Invalid executable/cwd, resize, partial I/O, immediate exit, repeated close,
  close during spawn, and a child ignoring termination all complete predictably.
- An interactive shell can run and interrupt a foreground job without killing
  tina; shutdown leaves no owned test children or worker behind.
- Tests allocate their own PTY. They must not require or open the developer's
  `/dev/tty`, and must run without `stdout.hasTerminal`.

## Phase 2 — terminal state and faithful input

Implement the emulator as pure Dart with incremental byte parsing. The existing
`packages/tina_console/test/virtual_terminal.dart` is a useful test helper, not a
production-ready emulator. Retain an independent rendering oracle in tests;
do not make both implementation and assertions depend on the same parser.

Required state and behavior:

- Incremental UTF-8 and escape parsing across arbitrary chunks; bounded OSC/DCS
  accumulation and recovery from malformed/unsupported sequences.
- Cell attributes, default/16/256/truecolor, cursor, save/restore, CR/LF/backspace,
  tab stops, delayed wrap, scrolling margins, erase/insert/delete, origin and
  autowrap modes, alternate screen, and cursor visibility.
- Wide and combining characters using the console's width conventions, with
  continuation cells and safe right-edge clipping. Do not defer this entirely:
  ordinary shell prompts and filenames can contain Unicode.
- Application cursor/keypad and bracketed-paste modes; query replies consistent
  with implemented capabilities. Consume unsupported control strings locally.
- Bounded primary-screen scrollback. Preserve the live screen when viewing
  history; alternate-screen state and history are separate. Define deterministic
  resize behavior (crop/pad initially; paragraph reflow can follow later).

Encode `InputEvent` according to emulator modes: text, paste, controls, arrows,
Home/End/Delete, function keys, and Alt combinations. Do not subscribe to global
stdin independently. Audit the parser as part of this phase: it currently drops
unmapped C0 controls, including Ctrl+Z and Ctrl+B, and maps some physical keys
to shared editing actions. Add sufficient events/provenance to preserve shell
job control, readline, and tmux prefix keys without changing chat behavior.
Update every exhaustive event switch and both backend input paths as needed.

Ctrl+G remains tina's escape route and is not sent to the child. Ctrl+W, Ctrl+C,
Ctrl+D, Ctrl+R, Escape, Tab, Shift+Tab, and app-shortcut keys otherwise belong to
the focused terminal. `ScrollEvent` already exists, but lacks coordinates for
full child mouse reporting: use it for local history initially. Forward ordinary
PageUp/PageDown to the child; do not steal application navigation for history.

Acceptance: table-driven byte/event tests plus parser-to-encoder round trips,
fragmented UTF-8/escape streams, malformed input, bounded history, resize,
wide-character boundaries, query responses, alternate-screen restoration, and
paste with bracketed-paste mode on/off. Test Ctrl+Z and Ctrl+B explicitly.

## Phase 3 — render through the existing panel contract

Implement `TerminalPanelContent implements PanelContent`; do not create a new
`Panel` subclass with its own border, focus registration, or layout branch.
Open through `PanelHost` with `PanelInputMode.exclusive` and existing placement.

Honor `fit`, `bindSurface`, `attach`, `detach`, and `repaint`. A bound surface is
borrowed from the frame: never destroy it. Support the existing unbound surface
path with explicit ownership. Clip all writes to the interior and skip empty
geometry. When parked, continue consuming output into bounded terminal state
without drawing; retain the last positive PTY size. On a positive size change,
resize state and notify the controller once, then repaint on attachment.

Render only sanitized grid content and locally generated styling through
`BackendSurface`; never forward raw child escape sequences to the outer
terminal. Coalesce dirty rows using the screen frame mechanism and an injected
scheduler; avoid per-byte redraws and idle animations. Closing cancels queued
paints before releasing surfaces. Validate both ANSI and notcurses paths.

Cursor ownership needs an explicit small seam: only the focused, visible panel
may request the terminal cursor position/visibility, and prompts/modals take
precedence. Restore chat cursor behavior on focus return. Do not overwrite the
coordinator's existing `frame.onFocus` callback or let background output move
the cursor. Add a composable focus/presentation hook if the existing API cannot
express this. Focus-reporting sequences, when enabled by a child, follow these
same transitions.

Acceptance: fake-surface tests for clipping, styles, dirty-row batching,
attach/detach, borrowed-surface lifetime, zero-size/tiny layouts, pending repaint
on close, cursor priority, and output while parked. Exercise tiled and sidebar
layouts and preserve all existing panel-host/input tests.

## Phase 4 — user command and lifecycle

Add `/term` to the existing command registry and completion list. It opens and
focuses one new shell in the project directory with a unique stable panel ID.
Resolve the user's configured shell from the launch environment, falling back
to `/bin/sh` when unset; report an invalid explicit shell rather than silently
changing it. Snapshot environment/cwd using the existing execution-environment
utilities; preserve HOME, PATH, and cache settings. Do not route the terminal
through agent tool approval, retry, or output-truncation machinery.

User-operated shells run with the user's normal OS permissions and network
access. State that plainly in terminal help; agent permission modes continue
to govern agent tools only. Agent-driven terminal access is separate future
work requiring its own policy design.

The shell starts once per explicit command. Track starting/running/exited/closing
states, and handle closing or application shutdown while spawn is pending.
A late spawn must be closed, never attached to an already-closed panel. On
natural exit, drain output and retain the final screen with exit status; do not
automatically respawn. Add `/term list` and `/term close <id>` so users can switch
to chat with Ctrl+G and explicitly close a running or exited terminal. Closing
a running terminal terminates its owned processes and removes its view.

No `s`/`x` shortcuts inside a running shell. No double-Escape app cancellation
while terminal input owns focus. Ctrl+C goes through the PTY to the foreground
job; Ctrl+D follows the child's line discipline. Background agent work and
terminal work have independent cancellation lifetimes. Opening an approval
must capture its answer completely, including buffered input and paste.

Acceptance: controller tests with a fake PTY cover open/focus, multiple shells,
launch error rollback, pending-spawn cancellation, exit-before-attachment,
output drain, repeated close, and awaited application shutdown. End-to-end
input tests cover switching to chat with its original draft, approval/modal
priority, and shell Ctrl+C without a chat `[cancelled]` notice.

## Phase 5 — compatibility and release gate

Do not enable `/term` in a release until these checks pass:

1. Required Linux and macOS PTY integration jobs, without a controlling outer
   terminal. Platform skips are allowed on unsupported systems; required CI
   targets must fail if native support cannot load.
2. Deterministic headless tests combining a real shell, emulator, and panel:
   prompt, text entry, command history, completion, resize, foreground interrupt,
   EOF/exit, and cleanup. Use deadlines to detect hangs, not timing assertions.
3. Interactive smoke tests for the packaged binary on all three release targets,
   covering opening a shell at normal and tiny sizes, focus switching, and quit
   with a live shell. Verify native asset installation and macOS signing.
4. Controlled `less`/`vim` alternate-screen checks and a tmux session using an
   isolated test socket with cleanup. Verify Ctrl+B, application arrows, paste,
   resize, and restoration. Advertise tested compatibility and list remaining
   gaps; mouse reporting and exact Ctrl+G passthrough remain outside scope.
5. Run affected engine, console, root command/host suites, static analysis, and
   architecture/import checks. Keep rendering tests independent of the emulator
   where possible. Existing cancellation, approval, and chat input tests must
   continue to pass.

Implement in phase order. Each phase should be reviewable with its acceptance
checks before the next integration step. The current task updates this plan
only; it does not implement or enable `/term`.
