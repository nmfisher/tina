---
id: tin-f5xt
status: open
deps: []
links: []
created: 2026-08-06T11:36:51Z
type: feature
priority: 2
assignee: Nick Fisher
tags: [sessions, attach, detach, tmux]
---
# Session attach/detach via tmux — thin integration

Tina persists sessions to disk (`~/.tina/sessions/<id>/` — per-turn JSONL append, manifest v2) but agents stop when the TUI exits; "resume" is a fresh process replaying from disk. The original plan was a built-in session daemon (background process, unix socket, virtual screen + grid sync) — ~1.8k lines of infrastructure reimplementing what tmux already does. **Decision: use tmux as the attach/detach substrate and add a thin in-app integration (~150 lines).** Users who run tina inside tmux get the full tmux story — detach keeps the agent running, reattach with full scrollback, `tmux ls`, works over ssh. Users who don't are completely unchanged.

## Scope (the thin integration)

1. **`/detach` command + `Alt+D` keybind.** If `$TMUX` is set → run `tmux detach-client` (the agent keeps running inside the tmux server; the terminal returns to the shell). If not → print a one-line hint — `not running in tmux — start tina with tmux new -s <name> to detach/attach` — and do nothing else.
2. **`/exit` becomes detach-or-kill inside tmux.** `/exit` and Ctrl+C×2 show a Detach / Exit / Cancel dialog when `$TMUX` is set. Exit behaves exactly as today (session saved, lock released, process exits); Detach leaves the agent running.
3. **Teardown hint.** When exiting inside tmux, the existing resume hint (`session saved: <id> … tina --resume <id>`) also prints the tmux reattach command (`tmux attach -t <session>`).
4. **One-time tmux notice.** First interactive run inside tmux shows a single dim notice that `--backend ansi` renders more predictably inside tmux than the notcurses default. Tracked with a marker under `~/.tina` so it appears once per install.
5. **Docs.** New `docs/features/session_attach_detach.md` (the pattern, keys, scrollback, lock behavior, `--backend ansi` note) + a line in `/help` and README.

## Non-goals

- No daemon process, no socket/IPC, no virtual screen, no protocol.
- No remote kill (`tmux kill-session` covers it), no multi-client, no in-app live-session listing beyond what exists.
- The per-session lock is unchanged: a second tina process on the same session still exits 1 with the existing message; `--force` still force-takes it. Inside tmux there is only ever one tina process per session, so the lock only guards the pathological case.

## Touch points

- `lib/session_commands/` — new `/detach` handler (`$TMUX` check + `Process.run('tmux', ['detach-client'])` / hint)
- `lib/tui_coordinator.dart` — `Alt+D` keybind; CmdExit / Ctrl+C×2 → detach-or-kill dialog when in tmux; teardown hint line (`_teardownAndHint`); one-time notice + marker
- `docs/features/session_attach_detach.md` (new), `/help` text, README

## Acceptance Criteria

Running tina inside tmux, `/detach` (and Alt+D) returns to the shell with the agent still running; reattaching with `tmux attach` shows the session exactly as left, including turns that completed while detached, with scrollback intact. Outside tmux, `/detach` prints only a one-line tmux hint and nothing else changes. `/exit` inside tmux offers Detach / Exit / Cancel — Exit behaves exactly as today (session saved, lock released); Detach leaves the agent running. Exiting inside tmux prints both the `tina --resume` and `tmux attach` commands. A first-run-in-tmux dim notice about `--backend ansi` appears exactly once. The per-session lock is unchanged: a second tina process on a locked session still exits 1, and `--force` still force-takes it.
