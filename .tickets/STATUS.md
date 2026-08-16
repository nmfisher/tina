# Sweep status
Now:     tin-m2vq CLOSED (resize-storm row merge, fixed + tested); corpus pass at 200x50 running
Next:    finish the 200x50 pass, then a fresh pass for anything new; PR for the session's fixes
Blocked: none
Ask:     tin-v6tq — how long the startup input drain should stay open (UX trade-off, proposal on the ticket); plus the parked feature tickets below
Last checkpoint: 2026-08-16 10:05 — tin-m2vq closed, tin-v6tq filed, tin-3x9v hunted 4 new angles (9 runs, no crash); branch: 2 commits over origin/main

## Closed this session

- tin-m2vq (p2) — rapid resizes mid-stream merged two chat rows into one
  ("streamed line 29streamed line 30"), persistently. Reproduced live
  (tool/crash_resize.sh, tool/merge_repro.sh) and as a VirtualTerminal
  regression test. Root cause: `_reconcileRows()` filled the shrunk
  buffer with content rows and clamped the write cursor onto the last of
  them, so the next append merged into it. Fixed by bounding the kept
  content rows by the cursor's post-clamp row. tina_console 678/678,
  root 540/540, live repro clean from a fresh restart.

## Filed this session

- tin-v6tq (p2, needs-user-decision) — terminal capability replies
  arriving after the startup drain window paste ~4.5 KB of garbage into
  the editor. Found while hunting tin-3x9v: a mid-run re-injection of
  the tin-r2vd reply bundle is NOT harmless. Low real-world incidence
  (notcurses blocks on its init queries, so replies are normally consumed
  before the app runs); the drain length is a UX trade-off — proposal on
  the ticket.

## Open (hunted / not in play)

- tin-3x9v (p1) — SIGSEGV at a pending approval while output streams.
  Four new harnesses this session (crash_replyburst, crash_oscstress,
  crash_resize, merge_repro — all committed), 9 runs attacking the one
  environmental factor both recorded crashes shared (the reply
  injection) plus palette races and resize storms: zero SIGSEGV. The
  likeliest explanation for the silence is that the crash's precondition
  (an approval stuck in the tin-8n7c vanish state, pump queue full, Dart
  not draining) no longer exists. Keep open; re-run crash_oscstress.sh +
  crash_replyburst.sh first if it recurs. Full notes on the ticket.
- tin-p2sq, tin-g7rk, tin-c5nw, tin-y4qn, tin-r2vd, tin-j3mk —
  pre-existing, not in play per the brief.
- tin-1h8p (auto-mode approval classifier), tin-80ll (drop workflow
  roles), tin-923l (unify workflow prompts), tin-f5xt (tmux
  attach/detach), tin-k9q3 (Linux bash sandbox) — verified open, all
  decided feature/proposal tickets from prior sessions, outside this
  sweep's defect loop; parked pending user prioritization.
- tin-m4qk — verified CLOSED (was listed open in the 2026-08-16 brief;
  closed in PR #10).

---
## Corpus results

| Task | 120x40 (prev session) | 80x24 (last session) | 200x50 (this session) |
|------|----------------------|----------------------|----------------------|
| T1 | PASS | PASS | running |
| T2 | PASS | PASS | pending |
| T3 | PASS | PASS | pending |
| T4 | PASS | PASS | pending |
| T5 | PASS | PASS | pending |
| T6 | PASS | PASS | pending |
| T7 | PASS | no answer in watch | pending |
| T8 | PASS | PASS | pending |
| T9 | PASS | no answer in watch | pending |
| T10 | PASS | PASS | pending |
| T11 | PASS | PASS | pending |
| T12 | PASS | no answer in watch | pending |
| T13 | NO-SHOW | PASS | pending |
| T14 | PASS | not rerun | not rerun (scenario) |
| T15 | PASS | NOT RUN | pending (prompt file recreated) |

## Notes

- t15.txt had to be recreated under /tmp/sweep-prompts/ again this
  session (the note claiming it was created last session did not hold).
  The corpus driver silently skips a task whose prompt file is missing —
  worth a guard in the driver.
- ~/.tina/config is on a read-only mount in this sandbox (by design, see
  writeUserConfig). To run against the stub, launch the app with
  HOME=/tmp/stubhome (a ~/.tina/config pointing provider stub at the
  stub server) instead of editing the user config — that is what the new
  hunt harnesses do.
- Toolchain: /home/agent/dart-sdk (3.13.0) for all builds/tests.
- Editing a bash script while an instance of it is running corrupts the
  running instance's parse — kill it first (this cost one wasted hunt
  run).
