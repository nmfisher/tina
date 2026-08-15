---
id: tin-j3mk
status: open
deps: []
links: []
created: 2026-08-15T00:00:00Z
type: bug
priority: 2
assignee: Nick Fisher
tags: [tui, notcurses, shutdown, crash]
---
# Teardown segfault: use-after-free after notcurses_stop

## Context

Found by the tui-smoke container run (2026-08-15). After quitting the notcurses TUI, the process crashes with SIGSEGV in `notcurses_stdplane` — a use-after-free on a background thread after `notcurses_stop`. The run printed "Aborted"; render and quit both worked, so this is a shutdown race.

## Repro

1. Start the tina TUI (notcurses backend) under tmux with the terminal-reply injection (see tin-r2vd).
2. Quit (Esc/quit key).
3. Process segfaults during teardown (SIGSEGV in `notcurses_stdplane`).

## Notes

- Possibly aggravated by the injected terminal input from the tin-r2vd workaround — needs confirmation on a normal terminal.
- A background thread still touches the plane after `notcurses_stop` — the race is between the stop and the thread's teardown.

## Acceptance criteria (for the fix run — not started)

- Clean exit: no crash, no "Aborted" after quit.
- Teardown orders the stop before the background thread's last plane access (join/barrier).
- Regression test where feasible; existing TUI tests keep passing.
