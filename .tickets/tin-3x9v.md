---
id: tin-3x9v
status: open
deps: []
links: [tin-8n7c, tin-j3mk]
created: 2026-08-15T16:20:00Z
type: bug
priority: 1
assignee: Nick Fisher
tags: [tui, crash, approvals, notcurses, segfault]
---
# SIGSEGV mid-run: pressing a key at a stuck approval prompt crashes the TUI

## Context

Two occurrences (2026-08-15, 120×40 detached-tmux harness with the tin-r2vd
reply injection, after the tin-8n7c readKey fix):

1. Fresh session, environment-agent first-load ceremony, first approval
   showing; the TUI crashed to the shell with "Segmentation fault" without
   any keypress (the crash happened between the approval render and the next
   keystroke).
2. Same setup, an approval that had ignored ~50 'y' presses at 6 s cadence
   (the tin-8n7c vanish); a single 'y' after a 15 s pause produced
   "Segmentation fault" and the shell prompt — the keypress was consumed by
   the dead process (the 'y' echoed in the shell).

The crash is a native SIGSEGV (not a Dart exception): the pane shows the raw
"Segmentation fault" line and the shell prompt returns. Distinct from
tin-j3mk (teardown-after-quit); here the TUI is mid-run at a pending
approval.

## Repro

1. Launch tina in detached tmux with the reply injection.
2. Wait for an approval prompt (the env-agent ceremony produces them).
3. Press a key (or in some runs, press nothing — the crash comes on its own).
4. Observed: "Segmentation fault", shell prompt returns.

Not every approval crashes — most resolve normally; the crash correlates
with approvals that have been "stuck" (see tin-8n7c's vanish).

Refined repro (5 occurrences by 2026-08-15 17:25): the crash lands while the
agent's tool output is STREAMING — e.g. a bash heredoc write or `dart run`
with "Running build hooks..." in flight — and a keypress arrives at the same
time (the editor renders the typed char). The last render before the crash
is the approval row + the streaming output row; the next keystroke's render
segfaults. No core dump is produced (Dart VM handles SIGSEGV itself) and no
VM crash dump reaches stderr — the shell just prints "Segmentation fault".
The crash also occurred once with no keypress at all, sitting at an approval.

## Notes

The approval path is askPermission → chat.write prompt → editor.readKey
(tui_conversation_host.dart). A native crash on the readKey/input path with
a stale input state suggests the notcurses input pump or the input-backend
drain touching freed memory (j3mk's teardown race is the same area).

## Acceptance

- No native crash: a keypress at any approval state resolves or denies the
  approval; the process never segfaults mid-run.
- Regression coverage: repeated approval cycles with keys at various
  cadences stay alive (the crash is native, so the regression is a
  soak/repeat test in the TUI harness rather than a unit test).

## Session findings (2026-08-16)

Crash not reproduced this session: ~25 automated runs (stub + real provider)
covering the ticket's conditions — first-load ceremony streaming while an
approval pends, approval resolved with the pause pattern, keys hammered
through long streaming tool output (120-line bash stream), real-provider
refactor turn. No SIGSEGV in any run.

Two render-path fixes landed in the same area (tin-4k8w, closed): the
mid-stream shrink reconcile and the post-resize full re-emission — both
harden the streaming render path the crash shared. Re-open if the crash
recurs after these.

Harness artifacts for re-attempts: tool/stub/scenarios/crash_stream2.txt
(ceremony-paced stream + 120-line streaming bash call),
tool/crash_hunt.sh / tool/vanish_hunt.sh (key-hammer + steady-cadence
drivers), tool/crash_gdb.sh (gdb wrapper for a native backtrace when it
does reproduce).

## Session findings (2026-08-16, continued)

No crash in 1 valid real-provider crash-hunt run (hammered y/x through a
full refactor turn with streaming approvals — the exact crash shape) +
1 vanish-hunt run + 1 debug run. NOTE: the session's first crash-hunt run
was invalid — the terminal-reply injection landed during a cold dart
build (cache invalidated by pub get) and the app hung at notcurses init
(tin-r2vd), so "alive" meant nothing. crash_hunt.sh / crash_gdb.sh /
tina_sweep_task.sh now wait for the build to finish before injecting
(commit a39713f); re-verify with the fixed harness. The 80×24 corpus
pass doubles as crash hunting (each task runs approvals + streaming +
keys at the crash's cadence).

## Session findings (2026-08-16, continued #3 — four new hunt angles)

The one environmental factor both recorded crashes shared is the tin-r2vd
reply injection; on 2026-08-15 it fired on a fixed sleep, so it could land
mid-run rather than inside notcurses' init window. Four new harnesses
(committed under tool/) attacked that and the other native hazards
directly — 9 runs, zero SIGSEGV:

| Harness | What it does beyond crash_hunt.sh | Runs | Result |
|---------|-----------------------------------|------|--------|
| crash_gdb.sh | real provider under gdb, backtrace on any SIGSEGV | 1 | no crash |
| crash_replyburst.sh | stub, the FULL reply bundle re-injected mid-run at 12 s / 30 s / 55 s while streaming + keys | 3 (+1 real provider) | no crash |
| crash_oscstress.sh | stub, ~10 Hz palette probes (OSC 4 + OSC 11 + DA1) for 45 s while streaming + keys — widest window on the "input automaton writes palette while rasterize reads it" race | 2 | no crash |
| crash_resize.sh | stub, grow/shrink storm (120×40→80×24→60×15→200×50, 0.4 s cadence) while streaming + keys — plane geometry churn | 2 | no crash |

Notes:

- The mid-run reply bundle does not crash the app, but it is **not**
  harmless: notcurses passes the OSC bytes through as key events after
  its init window and the editor gains ~4.5 KB pasted garbage per burst
  (filed as tin-v6tq). This is also a plausible account of the original
  crashes' environment — but it did not crash once in 4 runs, so the
  reply-burst hypothesis is now weakened, not confirmed.
- The pump thread's `notcurses_get_nblock` racing the main isolate's
  `notcurses_render` remains the only standing native concurrency in the
  design; crash_oscstress.sh is the harness to re-run if the crash
  recurs.
- Most likely explanation for the silence: the crash's precondition — an
  approval stuck in the tin-8n7c vanish state, where the pump's 256-slot
  queue fills and Dart stops draining — no longer exists after the four
  tin-8n7c fixes. Keep open; re-run crash_oscstress.sh +
  crash_replyburst.sh first if it recurs.

## Session findings (2026-08-16, continued #4 — union harness)

`tool/crash_union.sh` fires all three previously-isolated hazards at once,
on the reasoning that both recorded crashes shared every condition
simultaneously (approval pending + output streaming + a keypress) and a race
may need the full overlap: the complete reply bundle re-injected mid-run at
four points (measured 4837 key events in ~200 ms — far past the pump's
256-slot queue cap, so the pump thread blocks in `pump_push` while the
isolate renders), a 0.4 s resize storm across 120x40/80x24/60x15/200x50, and
a `y` key every 0.4 s.

**3 runs, zero SIGSEGV.** Running total across all hunt harnesses: 12 runs,
no crash.

Two additions to the record:

- The union harness *does* reproduce the tin-v6tq symptom live — the final
  pane shows the reply bytes pasted into the editor
  (`0/0000\[?2026;1$y[?1;3;256S...yyyyyyy`). So the input path is being
  stressed exactly as intended; it degrades to garbage input, not to a native
  crash.
- Queue saturation is now a *measured* property of the burst, not a
  hypothesis: 4837 records against a 256 cap means the pump thread spends
  most of the burst blocked on `not_full`. That makes the
  `notcurses_get_nblock` (pump thread) vs `notcurses_render` (main isolate)
  overlap — the only standing native concurrency in the design — exercised
  hard by this harness, and it still does not fault.

Also relevant from the tin-v6tq work: `notcurses.h` makes no thread-safety
statement at all (no "thread" mention in the 3.0.17 header), so that
concurrency remains undocumented upstream rather than confirmed safe.
Keep open; if it recurs, crash_gdb.sh (real provider, backtrace on fault) is
the first harness to reach for, then crash_union.sh.
