# Sweep status

Now:     wrapping up — corpus run at 120×40 + 80×24; 4 new tickets filed (2 p1), 2 closed; PR next
Next:    (sweep done) — the open p1s (tin-3x9v crash, tin-4k8w corruption) need the render/input internals
Blocked: none
Ask:     none
Last checkpoint: 2026-08-15 18:20 — corpus: T1-T15 (T13 model no-show), 2 geometries, seeds done; suites green (root +538, tina_console +670); branch pushed via git data API

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
