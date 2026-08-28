# Session attach/detach via tmux — the thin integration

**Status:** Implemented
**Date:** 2026-08-28
**Ticket:** tin-f5xt

## 1. The change in one paragraph

Tina persists sessions to disk (`~/.tina/sessions/<id>/` — per-turn JSONL
appends, manifest v2) but the agent stops when the TUI exits; "resume" is a
fresh process replaying history from disk. The original plan for true
attach/detach was a built-in session daemon — a background process holding a
unix socket, a virtual screen, grid sync — roughly 1.8k lines of infrastructure
reimplementing what tmux already does. Instead, tina treats **tmux as the
attach/detach substrate** and adds a thin in-app integration (~150 lines). Users
who run tina inside tmux get the full story: `/detach` returns to the shell with
the agent still running, `tmux attach` restores the session exactly as left —
including turns that completed while detached — with scrollback intact, and
everything works over ssh. Users who don't run under tmux see no change at all.

## 2. The pattern

```
$ tmux new -s tina          # a named tmux session
$ tina                      # the TUI runs as a client of that session
…work…
/detach        (or Alt+D)   # → back at the shell; tina keeps running
$ tmux attach -t tina       # later: same screen, same scrollback
```

The `$TMUX` environment variable decides everything. tmux sets it for every
client it spawns (the server's socket path), so a single lookup partitions the
two worlds:

- **`$TMUX` set** — tina is a client of a tmux server. The process can outlive
  the terminal, so `/detach`, the exit dialog, and the reattach hint are all
  live.
- **`$TMUX` unset** — tina is attached to its terminal for life. `/detach`
  prints one dim line and does nothing else; `/exit` and Ctrl+C×2 exit exactly
  as before; the teardown hint shows no `tmux attach` line.

All of that lives in `lib/tmux/tmux_support.dart` (`TmuxSupport`). It is a
plain class with the environment injected as a map and the one side effect —
spawning `tmux detach-client` — behind a `ProcessRunner` seam, so the parsing
and decision logic is unit-testable without a tmux server.

## 3. Keys and commands

| Action | Inside tmux | Outside tmux |
| --- | --- | --- |
| `/detach` or **Alt+D** | `tmux detach-client` → shell, agent keeps running | one-line hint, nothing else |
| `/exit`, `/quit` | **Detach / Exit / Cancel** dialog | exits immediately |
| Ctrl+C×2, Ctrl+D, EOF | **Detach / Exit / Cancel** dialog | exits immediately |

Both entry points to a detach — the command and the keybind — call the same
seam (`SessionController.detachTmux`), so they share one implementation and
read identically. The keybind is consumed before the line editor's own Alt+D
(`kill-word-forward`), so Alt+D is a detach gesture everywhere in tina now.
The coordinator's closure checks `$TMUX` and prints the one-line hint when it
isn't set, so the gesture is never a silent no-op.

- **Detach** runs the detach and returns to the shell mid-await. The messages
  tina would have shown land in the session's transcript instead, ready for
  reattach.
- **Exit** is today's behavior exactly: session saved, lock released, process
  exits.
- **Cancel** (or Esc) keeps running.

## 4. Teardown hint

When tina exits inside tmux, the existing resume hint gains a third line:

```
session saved: 20260828-101414-ab12 (42 messages)
resume: tina --resume 20260828-101414-ab12
        tina -c
        tmux attach -t tina
```

The target comes from the `$TMUX` socket path (`/tmp/tmux-1000/default,12345,0`
→ `default`), so it names the server you're actually attached to, not a guess.
Outside tmux the line is simply absent — `resumeHintText` takes the attach line
as an optional argument and appends it only when non-empty.

## 5. The per-session lock is unchanged

Detaching does **not** release the session lock, because the process is still
alive and still owns the session. The lock only guards the pathological case:
a second `tina --resume <id>` against a detached-but-running session still
exits 1 with the existing message, and `--force` still takes it. Inside tmux
there is only ever one tina process per session, so in practice you reattach
(`tmux attach`) rather than resume.

## 6. `--backend ansi` inside tmux

The notcurses backend (the default) renders less predictably inside tmux than
the ANSI one does. Rather than nag on every start, the first interactive run
inside tmux on notcurses drops a single dim line into the chat:

```
running under tmux: `--backend ansi` renders more predictably inside tmux than the notcurses default
```

The appearance is tracked by a hidden marker file — `~/.tina/.tmux_notice_shown`
— so it shows exactly once per install. The write is best-effort: a read-only
`~/.tina` means the notice can reappear once more, which is the right failure
mode for a nicety.

## 7. Non-goals

- No daemon process, no socket/IPC, no virtual screen, no protocol.
- No remote kill — `tmux kill-session` covers it.
- No multi-client coordination beyond what tmux itself does.
- No in-app live-session listing beyond what `/sessions` already shows.

## 8. Touch points

- `lib/tmux/tmux_support.dart` — `TmuxSupport`: `$TMUX` detection, attach-target
  parsing, `detach-client` spawn, the once-per-install notice + marker.
- `lib/session_commands/command_context.dart` — the `detachTmux` /
  `onTmuxExit` seams and the `TmuxExitChoice` enum.
- `lib/session_commands/session_command_handlers.dart` — `/detach`
  registration, dispatch, and the `/help` line.
- `lib/session_controller.dart` — the controller-side seam fields and
  `_handleExitIntent`, which unifies `/exit` and the quit attempts.
- `lib/tui_coordinator.dart` — Alt+D on the editor's `onAltKey`, `TmuxSupport`
  construction, the exit dialog, the detach closure, the teardown hint's attach
  line, and the one-time notice.
