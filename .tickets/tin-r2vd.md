---
id: tin-r2vd
status: closed
deps: []
links: [tin-v6tq, tin-3x9v]
created: 2026-08-15T00:00:00Z
closed: 2026-08-17T00:30:00Z
type: bug
priority: 1
assignee: Nick Fisher
tags: [tui, notcurses, tmux, init]
---

# notcurses init blocks forever in a detached tmux session

## Context

Found by the tui-smoke container run (2026-08-15). tina's notcurses TUI cannot
start in a detached tmux session: it blocks indefinitely at
`NotcursesBackend.create`.

## Cause

notcurses 3.0.17 sends ~2.8 KB of terminal queries at init (DSRCPR, DA1,
XTMODKEYS, the 256-entry OSC 4 palette, OSC 10/11, DECRPM) and then blocks in
`inputlayer_get_responses` (src/lib/in.c) on a condition variable with **no
deadline** until the DA1 reply arrives. A detached tmux server has no attached
client to answer the OSC queries — and, as measured here, it does not answer
DA1 either when detached — so init never returns.

There is no way to bound that wait through the library: no init flag skips the
queries (`NCOPTION_DRAIN_INPUT` means "never read keyboard input", see the
comment in `_LiveNotcursesPlatform.init`), and the library is statically
linked, so it cannot be patched.

## Fix

`TerminalReplyGuard` (packages/tina_console/lib/src/backend/
init_reply_guard.dart), run around the `nc.NotCurses(...)` construction:

1. Before init, ask the terminal OSC 10/11 with echo temporarily off (raw
   mode captured and restored). OSC 10/11 — not DA1 — deliberately: a lone
   early DA1 would complete notcurses' init wait before the palette replies
   arrived, silently losing colour detection for every attached user.
2. Reply within 400 ms → stand down; init is untouched and the normal path
   is exactly as before.
3. No reply → the terminal is mute: put a pty this process owns onto fd 0,
   make its slave raw, and feed it `\x1b[?62;22c` (DA1, VT220 + ANSI colour,
   claiming nothing else) from the master side. notcurses reads it off fd 0,
   its init wait releases, and init completes on terminfo defaults — the
   "proceed with defaults after a bounded wait" path.
4. After init returns (success or failure), fd 0 is swapped back to the real
   stdin with O_NONBLOCK set, so the input path for the rest of the session
   is identical to what it would have been without the guard.

Every step is failure-tolerant: non-tty stdio, a termios that cannot be
changed, or a system without `openpty` all leave startup exactly as it was.

## Repro / verification

- `tool/verify_init_guard.sh` — phase A launches the TUI in a detached tmux
  with **no** reply injection and asserts it renders, takes keyboard input,
  and quits; phase B answers the guard's own probe (simulating an attached
  terminal) and asserts startup still works and the shell comes back with
  echo intact. Both pass.
- Before the fix the same launch sat at a blank pane forever (reproduced at
  the head of this session; injecting a single 9-byte DA1 was enough to
  release it, which is what pinned the cause).
- `packages/tina_console/test/init_reply_guard_test.dart` — 8 tests over the
  decision logic and fd choreography (probe ordering, echo-off window,
  drain-on-answer, stand-down paths, no-detour paths, throw containment).
- Root suite (540) and tina_console suite (706) green; `dart analyze` shows
  no new issues.
- `tool/verify_reply_filter.sh` (stub provider) still passes — the reply
  filter and the guard coexist.

## Notes

- The startup injection in the older harness scripts is now redundant but
  harmless: replies injected after launch arrive as key events and are
  dropped by the ReplySequenceFilter (tin-v6tq). Mid-run injection harnesses
  (crash_replyburst, crash_union) are unaffected — injecting mid-run is their
  purpose.
- If the guard detours, notcurses gets no palette/fg/bg detection and the
  theme falls back to terminfo defaults. That only happens on a terminal that
  answered nothing at all, which by definition has nothing to detect.

## Acceptance criteria

- [x] notcurses init does not hang when terminal replies are missing — the
      probe bounds the wait at 400 ms.
- [x] TUI renders under detached tmux without injected replies.
- [x] Regression test: unit suite + `tool/verify_init_guard.sh` live check
      (the "fake terminal that does not answer" case is phase A; the
      answering terminal is phase B).
