# Interactive terminal panel — remaining implementation

Status: specification, updated against v0.6.30 on 2026-09-16. The generic
[panel host](panel_architecture.md) and native [PTY backend](pty_backend.md)
are implemented. This plan contains only the work required to turn those
components into a usable terminal. `/term` is not implemented yet.

## User contract

From a conversation, `/term` opens and focuses a new interactive shell in the
project directory. The shell supports command editing, history, completion,
foreground jobs, Unicode, resizing, and terminal applications. Ctrl+G enters
Tina's existing focus navigation; selecting a conversation restores its draft.
Returning to a terminal preserves its process, screen, and history.

| Command or action | Required result |
| --- | --- |
| `/term` | Create one terminal with a unique `term-<n>` ID and focus it. |
| `/term list` | Show IDs, shell names, initial working directories, and lifecycle states. |
| `/term focus <id>` | Focus an existing running or exited terminal. |
| `/term close <id>` | Await process cleanup and remove the panel; repeated close is harmless. |
| Shell `exit` or Ctrl+D at an empty prompt | Retain final output and show exit status; do not restart automatically. |
| Ctrl+C inside a terminal | Send ETX to the PTY foreground job; do not cancel an agent or quit Tina. |
| Ctrl+G, select chat, `/quit` | Await all terminal shutdowns before tearing down the screen. |

Commands are entered in the chat editor, never intercepted from shell text.
`/term --help` explains navigation, closing, and that these user-operated shells
have the user's normal filesystem and network access. Agent permission modes
continue to apply to agent tools. Do not expose terminal input/output to agents.

Target Linux x64/arm64 and macOS arm64. No Windows backend, process restoration
on `--continue`, remote reattachment, mouse reporting to children, or complete
xterm compatibility in this implementation. Do not serialize shell contents
into conversations or restart shells from persisted panel IDs.

## Boundaries and composition

Keep the existing engine and console packages independent. New components:

| Component | Location | Responsibility |
| --- | --- | --- |
| `TerminalEmulator` and terminal state types | `packages/tina_console/lib/src/terminal/terminal_emulator.dart` | Incremental byte parsing, grids, modes, scrollback, damage, query replies. Pure Dart. |
| `TerminalInputEncoder` | `packages/tina_console/lib/src/terminal/terminal_input_encoder.dart` | Convert input events to bytes using current emulator modes. |
| `TerminalPanelContent` | `packages/tina_console/lib/src/terminal/terminal_panel_content.dart` | Render a terminal viewport through `PanelContent` and `BackendSurface`. |
| `TerminalPanelController` | `lib/tui/terminal_panel_controller.dart` | Own sessions, bridge engine/console, coordinate focus, writes, resize, and awaited cleanup. |
| Terminal command capability | Existing session-command adapter and registry | Dispatch open/list/focus/close to the controller without importing FFI or terminal state into the app layer. |

Use an injected session factory in the controller with a small connection
interface: `output`, `done`, `write`, `resize`, and `close`. Its production
adapter wraps the existing `PtyRunner`/`PtyConnection`; fake connections can
complete spawn, output, exit, and close separately. Do not redesign PTY launch
or add shell-specific behavior to `ProcessTool`/`RunningProcess`.

The following is the intended integration, not an API that already exists:

```text
PTY output -> emulator.feed(bytes) -> dirty rows -> scheduled panel paint
                                    -> query replies -> ordered input writer
focused InputEvent -> input encoder(emulator modes) -> ordered input writer
panel positive size -> emulator.resize(rows, cols) + PTY.resize(rows, cols)
PTY output done + PTY.done -> final paint -> exited status
explicit close / application quit -> await PTY.close -> dispose view
```

Retain the in-tree implementation approach; do not add a third-party terminal
package. Build in the phases below, with each phase's checks passing before
connecting the next layer. Keep `/term` unavailable until the release gate.

## Phase 1 — terminal state and parsing

Implement a pure Dart emulator, with no `Screen`, filesystem, process, or timer
dependencies. Proposed public operations are `feed(List<int>)`,
`resize(rows, cols)`, `reset()`, a read-only viewport/state snapshot, and
`takeDamage()`. `feed` reports generated reply bytes and title/bell events;
it never writes to a terminal or creates a process.

State must include a primary grid, alternate grid, cursor with pending-wrap
flag, saved cursor state, scroll margins, tab stops, active attributes, modes,
and a bounded primary scrollback ring. Each cell stores its text cluster,
width/continuation marker, and attributes. Use the console's width conventions.
Erase/overwrite/resize must clear both halves of a wide glyph. Bound combining
marks per cell (64 code points), replacing further marks rather than growing
one cell indefinitely.

Implement these behaviors explicitly:

| Family | Minimum implementation |
| --- | --- |
| Text/control | Incremental UTF-8 with replacement for malformed input; CR, LF/VT/FF, BS, HT, BEL; default tab stops every eight columns. |
| Cursor | CSI A/B/C/D/E/F/G/H/f/d, save/restore (ESC 7/8 and CSI s/u), index/reverse index/next line (ESC D/M/E). Clamp to applicable bounds. |
| Editing | CSI J/K/X, insert/delete characters (@/P), insert/delete lines (L/M), scroll up/down (S/T), margins (r). |
| Attributes | SGR reset, bold, faint, italic, underline, inverse, conceal, strike; default/16/256/RGB foreground and background; selective resets. |
| Modes | Insert mode, origin, delayed autowrap, cursor visibility, application cursor/keypad, bracketed paste, focus reporting. |
| Screen switching | DEC 47/1047/1048/1049 with their separate save/clear/restore semantics; primary history survives alternate-screen use. |
| Character sets | DEC line-drawing designation and SI/SO selection, so common terminal application borders render correctly. |
| Queries | DSR status/cursor position and a documented, conservative device-attributes response; answers reflect active coordinates and capabilities. |
| Strings/reset | OSC title 0/2 produces a sanitized local title event; OSC/DCS/SOS/PM/APC are consumed locally; RIS resets state. |

Parsing is a persistent state machine, including incomplete UTF-8, CSI, and
string terminators split across chunks. Cap a sequence at 4096 bytes and CSI
parameters at 32; on overflow, discard the remaining sequence through its
terminator (CAN/SUB abort it). Never render discarded payload as ordinary
text. Unknown completed sequences are ignored. OSC clipboard, hyperlinks,
images, and outer-terminal commands have no side effects. Map BEL to a local
event, not an uncontrolled outer-terminal write.

Default history limits: 10,000 rows AND 1,000,000 stored cells, evicting oldest
rows when either is exceeded. Screen cells are additional, bounded by validated
geometry. Test with smaller injected limits. Full-screen primary scroll adds
history; scrolling a partial region or alternate screen does not. History
viewing must not stop consumption of live output. Preserve the viewport anchor
while output arrives; clamp it if eviction removes the anchor. Wheel scrolls
local history, and typing returns the viewport to the live cursor.

Resize initially crops/pads both grids without paragraph reflow, clamps cursor
and saved positions, clears orphan continuations, resets margins to the full
screen, and adds default tab stops in new columns. It does not invent history
from cropped rows. Zero-sized panel geometry never reaches the emulator or PTY;
retain their last positive dimensions until the panel becomes visible again.

Acceptance: table-driven sequences with expected cells/cursor/modes; replay
every fixture as one chunk, byte-by-byte, and at each possible split; malformed
and overlong sequences; Unicode edge cells; bounded history; alternate screen;
resize; and query reply bytes. Hand-written expected grids are the oracle, not
the production parser. Do not promote `test/virtual_terminal.dart` into the
production emulator and then use it to assert its own output.

## Phase 2 — preserve keys and encode input

Audit both ANSI and notcurses input adapters. Existing `InputEvent` values lose
some physical-key distinctions and C0 controls. Add a raw control-byte event
and physical-key/modifier provenance where required, preserving current chat
editing behavior. Explicitly cover Ctrl+A/B/E/F/K/N/P/U/Y/Z and Ctrl+Space,
Enter versus Ctrl+J, Backspace versus Delete, and Home/End versus Ctrl+A/E.
Update all exhaustive event switches. Do not add a second stdin subscription.

The encoder returns bytes or a local viewport action. It reads modes from the
emulator at the time of the event. Define and test this mapping:

| Input | Child bytes / action |
| --- | --- |
| Text | UTF-8, without chat expansion or trimming. |
| Enter / Tab / Backspace | CR / HT / DEL. |
| Ctrl+C/D/Z/B and other C0 keys | Their original control bytes; Ctrl+G is consumed by Tina before encoding. |
| Escape / Alt+character | ESC / ESC followed by the original UTF-8 character (preserve case). |
| Arrows | CSI A/B/C/D normally, SS3 A/B/C/D in application cursor mode. |
| Home/End, Insert/Delete, PageUp/PageDown, F1–F12 | Explicit VT/xterm key table, including supported modifiers; PageUp/PageDown go to the child. |
| Shift+Tab | CSI Z; do not change agent permission mode. |
| Keypad | Numeric or application keypad bytes according to mode and available physical-key information. |
| Paste | UTF-8 payload in one ordered transaction; wrap with CSI 200~/201~ only when bracketed paste is enabled. |
| Wheel | Local scrollback; no child mouse protocol in this release. |

Unsupported key encodings are consumed, never passed into chat or application
shortcuts. Unknown outer escape sequences are not blindly relayed: terminal
replies and key presses must be distinguished. Focus in/out produces CSI I/O
only when requested by the child and the terminal actually gains/loses effective
input focus, including prompt/modal takeover.

Controller input writes and emulator query replies share one ordered queue.
Await each `write` and handle `false`/errors as interrupted delivery. PTY chunking
does not bound the caller's pending queue: cap controller pending input at 1 MiB,
including the in-flight payload. Reject a paste/event that cannot fit as a whole
and show a local notice; do not silently truncate or partially enqueue it. Clear
queued input on close or exit. Never let an input future stall the UI event loop.

Acceptance: parser-to-encoder tests for both input backends, all C0 controls,
mode-dependent keys, Unicode Alt/text, paste boundaries, query/write ordering,
queue overflow, and shutdown during blocked input. Existing chat editing,
approval capture, and cancellation tests must remain green.

## Phase 3 — panel rendering and presentation ownership

Implement `TerminalPanelContent implements PanelContent`. Its constructor takes
terminal state, an injected paint scheduler, and a positive-size callback;
it receives no engine objects. Reuse the frame's bound `BackendSurface` and
never destroy that borrowed surface. If the existing unbound-surface path is
used, explicitly own and dispose that surface. Implement fit/bind/attach/detach/
repaint; detach means parked, not disposed or process-closed.

Within `Screen.frame`, paint only dirty visible rows, batching adjacent cells
with equal attributes into safe text/SGR runs. Erase stale cells, clip every
write, and never emit child escape strings to the parent terminal. Generated
SGR comes only from normalized cell attributes. First paint, resize, surface
rebind, and reattach invalidate the whole viewport. Parked panels continue
parsing output without drawing. Use at most one scheduled paint per frame
(default maximum 60 Hz), cancel it on disposal, and do not animate idle borders.

Add a small composable focus/presentation hook for terminal cursor ownership.
Do not overwrite the coordinator's existing `frame.onFocus`. A focused,
attached, live-viewport terminal may request its cursor position/visibility;
background panels and history view may not. Prompts/modals take precedence,
and chat focus restores the editor cursor. Make this arbitration shared by
ANSI and notcurses backends; background output must not move the outer cursor.

Acceptance: fake-surface tests cover dirty-row batching, style resets, clear
and wide-cell behavior, borrowed ownership, reattachment, hidden output,
zero/tiny dimensions, resize callbacks, cursor priority, and cancellation of
pending paints. Exercise both tiled and sidebar layouts with existing host and
focus APIs. Rendering tests inspect writes independently of emulator parsing.

## Phase 4 — controller, commands, and shutdown

Create the controller in application composition alongside `PanelHost`. Inject
session factory, shell resolver, environment snapshot, ID generator, focus
callback, and scheduler. Expose only open/list/focus/close through the existing
session-command capability pattern; command handlers should contain no PTY,
FFI, drawing, or shell-string construction. Add registry/help/completion tests
and a clear unsupported-frontend result for noninteractive command dispatch.

Resolve `SHELL` from the launch environment, falling back to `/bin/sh` only
when unset/empty. Resolve a bare name through the snapshotted PATH; validate an
explicit path. Pass `['-i']` as literal argv for the supported Unix shells
(sh/bash/zsh/fish); this is a non-login shell. Do not wrap launch in `sh -c`.
Report unsupported shell/exec errors with the selected executable and cwd.
Use the configured project directory as initial cwd; do not infer the shell's
later cwd from output or titles.

Pass a copied launch environment, preserving HOME/PATH/cache settings. Never
populate it from provider credentials or an agent's modified tool environment.
Replace stale terminal variables (TERM, COLORTERM, TERM_PROGRAM, LINES/COLUMNS,
and inherited TMUX/STY identifiers) with this terminal's own profile. Maintain
a checked-in capability/key/query matrix for that profile. Use `TERM=dumb`
for development until compatibility gates pass; select `xterm-256color` only
when its advertised subset, 256-color rendering, and application checks pass.
Advertise truecolor separately only after RGB tests pass. Do not install a
custom terminfo entry as a hidden startup side effect.

Each session has `starting -> running -> exited` or `failed`, and any state
may enter `closing -> closed`. Store one close future per session. Start with
these steps (the adapter/emulator/view APIs below are proposed):

```text
open():
  allocate ID + emulator + view; register exclusive panel through PanelHost
  store starting session; focus with the existing focusManager.focusPanel
  await sessionFactory.spawn(shell, ['-i'], cwd, env, positive size)
  if close was requested while awaiting: await connection.close(); finish close
  otherwise:
    attach output listener immediately (startup bytes are retained by PTY)
    apply latest positive geometry, not the size captured before spawn
    feed bytes to emulator; enqueue replies; schedule dirty-row paints
    start observers for both output completion and connection.done
    enable input and mark running without stealing focus a second time
```

If no positive layout exists at spawn, use 24 rows by 80 columns provisionally.
Ignore keystrokes while starting and show that state. Spawn errors become one
visible failure state without an unhandled future or leaked process. If panel
registration fails, do not spawn. A connection arriving after a close request
must be closed and never attached to a disposed view.

On natural exit, wait for BOTH stream completion and `connection.done` before
showing final exit status. `done` alone does not guarantee the consumer has
read retained bytes. Keep the final emulator screen and scrollback until the
user closes it; input after exit is consumed with an exited hint. Stream/write
errors enter a visible failed state and initiate awaited cleanup; catch errors
on every asynchronous observer.

Explicit close disables input, marks closing, and awaits any pending spawn and
PTY close. Keep consuming final output until stream completion, then remove the
view via `PanelHost.closePanel`, release subscriptions/scheduled paints, and
restore focus through the existing host behavior. A synchronous `onDispose`
may request cleanup but cannot be its awaited owner: retain the controller's
session record until cleanup finishes. Unexpected host disposal follows the
same idempotent close path. Do not pause output merely because a view is hidden.

Register an awaited `shutdown()` with application cleanup before screen/host
disposal. It blocks new opens and joins all close futures, including pending
spawns; keep `ChildProcessRegistry` as the fallback already supplied by PTY.
Do not add independent PID killing or a shorter timeout that abandons cleanup.
Keep agent cancellation independent. While a terminal is focused, Ctrl+W,
Ctrl+R, Ctrl+O, Escape, and double Escape belong to the child; only Ctrl+G
activates Tina navigation. Prompts/modals own their complete input batches.

Acceptance: fake-session controller tests cover all state transitions, multiple
shells, focus, spawn rejection, close-before-spawn, exit-before-listen, output
finishing after `done`, write errors, repeated close, registration rollback,
host disposal, and application quit. Assert no duplicate listeners/spawns and
no unresolved cleanup futures. Integration tests cover preserved chat drafts,
approval key/paste isolation, and shell Ctrl+C without chat cancellation text.

## Phase 5 — enable and ship the terminal

Add a runnable integration example using the actual emulator/controller/view
APIs once they exist; the [headless PTY example](pty_backend.md#runnable-shell-example)
is only a backend demonstration. Document `/term`, `/term list`, focus, close,
Ctrl+G navigation, Ctrl+C interrupt, and the lack of session restoration in user
help and release notes. Mark each remaining phase complete only with evidence.

Before registering `/term` in a release:

1. Run deterministic end-to-end shell tests without `/dev/tty`: prompt, command
   submission, history arrows, Tab completion, UTF-8, resize/SIGWINCH, foreground
   interrupt, job suspend/resume, EOF, natural exit, and descendant cleanup.
   Use controlled shell startup files and deadlines, not timing assertions.
2. Add fixtures for `less`, `vim`, and tmux on an isolated socket: alternate
   screen, Ctrl+B prefix, application arrows, paste, resize, and restoration.
   Capture expected screens independently. Document unsupported capabilities
   and the reserved Ctrl+G key; do not promise full xterm/tmux compatibility.
3. Extend packaged interactive smoke tests on Linux x64/arm64 and macOS arm64:
   open `/term`, execute a marker command, switch focus, resize to tiny/normal,
   interrupt a foreground job, and quit with a live shell. Assert no orphaned
   owned children or hung shutdown. Verify both native assets are installed and
   macOS signing/notarization still succeeds.
4. Gate on affected engine/console/root unit and integration suites, analyzer,
   architecture/import checks, and existing cancellation/approval/input tests.
   Required native CI jobs must fail rather than skip missing PTY support.

No earlier PTY implementation or generic panel refactor is part of these phases.
