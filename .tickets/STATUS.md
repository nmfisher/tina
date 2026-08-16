# Sweep status

Now:     tin-3x9v (p1, SIGSEGV) — root-cause hunt in the streaming render/input path
Next:    tin-3x9v (crash), then tin-6a2f (p2 approval overlap), tin-8n7c (p2 approval vanish)
Blocked: none
Ask:     none
Last checkpoint: 2026-08-16 02:10 — tin-4k8w CLOSED (2 commits: shrink-reconcile + post-resize refresh); suites green (root +538, tina_console +674)

## In flight

- tin-3x9v (p1) — SIGSEGV mid-run at a pending approval while tool output
  streams + a keypress. Not yet reproduced this session. Both tin-4k8w fixes
  harden the same streaming render area; re-attempt the crash repro with the
  stub + streaming before deeper native digging.

## Closed this session

- tin-4k8w (p1) — chat corruption on mid-stream resize, two root causes:
  1. `_reconcileRows` evicted the whole content on shrink with a
     partially-filled buffer (blank tail kept, content to scrollback) —
     fixed to keep the most recent content (92deaef).
  2. tmux keeps the bottom of the alt screen on pane shrink → terminal grid
     diverges from notcurses' retained frame → damage-only repaints leave
     dropped rows stale forever (the mid-row `└───` splice). Fixed with a
     full re-emission (`notcurses_refresh`) at the end of the canonical
     resize sequence (22bf97f).
  Live-verified: stub turn + 2 mid-stream resizes → content + frame intact.

## Open (unchanged this session)

- tin-3x9v (p1) — SIGSEGV mid-run at a pending approval (streaming + keypress).
- tin-6a2f (p2) — approval line overlap under rapid approvals.
- tin-8n7c (p2) — approval keys vanish at steady cadence (stale-paste part fixed upstream).

---
## Corpus results (120×40 unless noted)

| Task | Result | Notes |
|------|--------|-------|
| T1 | PASS | correct answer; raw markdown = tin-g7rk (known) |
| T2 | PASS | MemoryRepository + JsonFileStore with paths |
| T3 | PASS | diff preview red/green; single-file rename justified (corpus expectation "≥2 files" over-optimistic) |
| T4 | PASS | count command + track.dart wiring + docs (agent also wrote it in /tmp to verify) |
| T5 | PASS | git status summary matches the dirty state |
| T6 | PASS | 120×40 + 80×24; answer correct |
| T7 | PASS | error-recovery + partial index explanation |
| T8 | PASS | file-by-file trace rendered readably |
| T9 | PASS | headless; interface + both implementors touched |
| T10 | PASS | 120×40 + 80×24; CJK `决定缓存过期策略` renders correctly at both geometries |
| T11 | PASS | layout intact; note: read tool output not shown inline — the model claimed "shown above" without it being rendered |
| T12 | PASS | headless; barrel export removed + file deleted |
| T13 | NO-SHOW | model went off-task (env-record tangent); no region agents spawned; fleet UI unexercised |
| T14 | PASS | kill -9 mid-edit → --resume restores history; agent checked what was done and finished the rename |
| T15 | PASS | outside-cwd write gated (no silent write) |

Seeds: resize-mid-stream (corruption — tin-4k8w), ESC-at-approval (denies), paste-5k (harness-limited: tmux send-keys drops >~500-char args — delivery never reached tina), resume-with-truncated-session (handled gracefully).

## Findings this sweep (filed)

- tin-3x9v (p1) — SIGSEGV mid-run while tool output streams + keypress (5 occurrences; no core/backtrace captured yet).
- tin-4k8w (p1) — chat-region corruption: rows truncated ~35 cols with border spliced in during streaming; deterministic wipe on mid-stream resize.
- tin-6a2f (p2) — approval prompt line overlap under rapid approvals (live repro).
- tin-8n7c (p2) — approval input: stale-paste auto-deny FIXED (21af54e + regression test); steady-cadence key vanish remains open.
- tin-7b3p (p2) — root-suite flaky regression test — CLOSED (8b7dc36).
- Confirmed known: tin-g7rk (raw markdown incl. tables), tin-uzo3 (approval shows empty tool input), tin-y4qn (loading border gradient), tin-j3mk-adjacent teardown crash (one-off mid-run segfaults not re-filed separately).

## Notes

- Harness rebuilt: vendored notcurses 3.0.17 automaton cannot parse tmux's DA1
  reply (unit-test proven); `send-keys -H` broken on tmux 3.4; pty-slave writes
  are the output path. Working injection: named-key send-keys with a matchable
  DA1 (`\e[?62;c`). Scripts: tool/tmux_inject_replies.sh, tina_sweep_run.sh,
  tina_sweep_task.sh. Warm environment record (ENVIRONMENT.md + tracking.json)
  written into the fixture so the first-load ceremony doesn't run per launch.
- The corpus agents edited tool/sweep_tasks.md + docs + stub scenarios during
  runs (T12's agent rewrote T6/T7 to match its own deletion). Reverted. The
  "task sheet outside the fixture" isolation does not hold: the fixture's
  parent repo is visible to the agents. Harness-design note, not a tina bug.
- The steady-cadence approval vanish (tin-8n7c) forces slow approve loops;
  a press after a pause resolves.
