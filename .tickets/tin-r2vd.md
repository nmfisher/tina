---
id: tin-r2vd
status: open
deps: []
links: []
created: 2026-08-15T00:00:00Z
type: bug
priority: 1
assignee: Nick Fisher
tags: [tui, notcurses, tmux, init]
---
# notcurses init blocks forever in a detached tmux session

## Context

Found by the tui-smoke container run (2026-08-15). tina's notcurses TUI cannot start in a detached tmux session: it blocks indefinitely at `NotcursesBackend.create`.

## Cause

At init, this notcurses build sends ~2.8 KB of terminal queries: the full 256-entry OSC 4 palette, OSC 10/11 fg/bg, DECRPM, kitty/XTSMGRAPHICS. tmux answers DA1/DA2/XTVERSION/geometry itself, but a **detached server has no client to answer the OSC queries** — and the build waits forever instead of timing out. Confirmed with a minimal notcurses test program and a trace log (`block_on_input: blocking on input availability`).

## Repro

1. `tmux new-session -d -x 120 -y 40`
2. Run `dart run bin/tina.dart` inside the pane.
3. Screen stays blank; tina hangs at `NotcursesBackend.create` forever.

## Workaround (used in the smoke run)

Inject the missing replies into the pane with `tmux send-keys -H` after launch: CPR, DA1, the 256-entry OSC 4 palette replies, OSC 10/11, DECRPM 2026/1016. Init then completes and the TUI renders normally.

## Impact

Blocks the ui-sweep-loop harness (docs/ui-sweep-loop.md drives the TUI via detached tmux) and any headless/automated TUI run. The sweep harness brief needs this injection step until fixed.

## Acceptance criteria (for the fix run — not started)

- notcurses init must not hang when terminal replies are missing — time out or proceed with defaults after a bounded wait.
- TUI renders under detached tmux without injected replies.
- Regression test where feasible (fake terminal that does not answer OSC).
