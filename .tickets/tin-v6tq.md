---
id: tin-v6tq
status: open
deps: []
links: [tin-r2vd, tin-3x9v]
created: 2026-08-16T09:35:00Z
type: bug
priority: 2
assignee: Nick Fisher
tags: [tui, input, startup-drain, notcurses, paste]
---
# Terminal capability replies arriving after the startup drain window paste into the editor

## Context

Found 2026-08-16 while hunting tin-3x9v: `tool/crash_replyburst.sh`
re-fires the tin-r2vd terminal-reply bundle *mid-run* (12 s / 30 s / 55 s
into a turn). The pane then shows the replies inside the editor as pasted
text:

```
> [Pasted text : 32 chars]yyyyyyyy[Pasted text : 4570 chars]yyyy...
```

That is expected for a burst long after startup — but it also pins down
*when* the protection ends. `StartupDrain`
(packages/tina_console/lib/src/backend/notcurses_input_backend.dart)
discards input only while `isDraining` holds:

- always for the first 150 ms (`minWindow`);
- never past 1000 ms (`maxWindow`);
- between the two, only while events keep arriving within **30 ms** of the
  last one (`idleThreshold`).

So the drain closes as soon as the reply stream pauses for 30 ms — not at
1 s. A terminal that answers notcurses' init queries in a slow or bursty
fashion (mux relay, cold SSH link, a terminal that walks a 256-entry OSC 4
palette with gaps) has its late replies delivered to the app as key events.
notcurses does not consume OSC 4/10/11 after init, so the bytes surface as
CharInput; the PasteBurstDetector joins the cluster into one `PasteInput`
and the editor renders "[Pasted text : N chars]". A following Enter submits
the garbage as a prompt.

`tmux_inject_replies.sh` documents "stray duplicates of the replies are
harmless" — for the *harness* they are not: a mid-run re-injection pollutes
the editor with ~4.5 KB of paste per burst (this is how the run above was
noticed).

## Repro

1. `tmux new-session -d -x 120 -y 40 -s leak` and start tina there with the
   usual init reply injection (so it comes up).
2. Wait for the first-load ceremony to finish (any point past 1 s of input
   idle).
3. Re-run `tool/tmux_inject_replies.sh leak`.
4. Observed: the editor gains a `[Pasted text : ~4570 chars]` chip; the
   capability replies were not discarded.
5. Expected: replies to notcurses' own init queries are dropped whenever
   they arrive, or at least while no user keystroke has been seen.

Deterministic variant: `tool/crash_replyburst.sh` (stub server, scenario
`crash_stream2`) — every run shows two 4570-char paste chips.

## Acceptance

- A reply burst arriving at any point before the first genuine user
  keystroke is discarded, not pasted.
- A regression test over `StartupDrain` (fake clock) covers the
  bursty-reply case: events with >30 ms gaps inside the first second are
  still drained.
- The harness note in `tmux_inject_replies.sh` stops claiming stray
  duplicates are harmless.
