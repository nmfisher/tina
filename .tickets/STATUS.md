# Sweep status

Now:     80×24 corpus pass running (T1-T13 + T15, real provider) — doubles as the tin-3x9v crash hunt
Next:    finish corpus; fresh pass at 120×40; then PR
Blocked: none
Ask:     none
Last checkpoint: 2026-08-16 04:35 — tin-8n7c auto-deny path #2 reproduced & fixed (f5029cc); harness reliability fixes (a39713f); tin-uzo3 + tin-m4qk closed (verified done, suites green); branch rebased onto origin/main (PR #9)

## In flight

- tin-3x9v (p1) — SIGSEGV at a pending approval while output streams. No
  crash in the session's valid runs so far (1 fixed-harness crash hunt +
  corpus tasks in progress; the session's first hunt run was invalid — the
  reply injection landed during a cold build, see the ticket). Hunt
  harnesses fixed to wait out the build (a39713f). Re-open if it recurs.
- tin-8n7c (p2) — approval keys vanish. REPRODUCED + FIXED a second
  auto-deny path: a paste-burst flush (typed prompt held by the
  paste-burst detector) answers a pending approval readKey as a deny and
  swallows the prompt (f5029cc + regression test; live byte-order repro
  on the ticket). The steady-cadence vanish mode remains unreproduced
  (~15 further runs; keys during a running turn go to the queue by
  design).

## Closed this session

- tin-8n7c (p2, part) — stale-paste auto-deny, second path: paste-burst
  flush answering a readKey (see In flight).
- tin-uzo3 (p2) — tool args hidden in agent panels: verified fixed by
  7dd4949 (on main since Aug 8); tests green; closed.
- tin-m4qk (p2) — main-agent prompt/manager-loop alignment: all four
  items verified in code; root + tina_engine suites green; closed.

## Open (not in play / parked)

- tin-3x9v (p1) — SIGSEGV (see In flight).
- tin-8n7c (p2) — steady-cadence vanish (see In flight).
- tin-p2sq, tin-g7rk, tin-c5nw, tin-y4qn, tin-r2vd, tin-j3mk — pre-existing,
  not in play per the brief.
- tin-923l, tin-f5xt, tin-k9q3, tin-1h8p, tin-80ll — design/feature
  tickets from prior sessions, outside the UI sweep's scope; parked.

---
## Corpus results (120×40 from the previous session; 80×24 pass in progress)

| Task | 120×40 (prev) | 80×24 (this session) |
|------|---------------|----------------------|
| T1 | PASS | in progress |
| T2 | PASS | in progress |
| T3 | PASS | in progress |
| T4 | PASS | in progress |
| T5 | PASS | in progress |
| T6 | PASS | in progress |
| T7 | PASS | in progress |
| T8 | PASS | in progress |
| T9 | PASS | in progress |
| T10 | PASS | in progress |
| T11 | PASS | in progress |
| T12 | PASS | in progress |
| T13 | NO-SHOW (off-task) | in progress |
| T14 | PASS (kill-9/resume) | not in this pass (scenario) |
| T15 | PASS | in progress |

## Notes

- Toolchain: the host's shell uses /home/agent/dart-sdk (Dart 3.13.0);
  the agent shell resolves /opt/flutter/bin/dart (3.11.0 fork, kernel
  format 138 vs 127). Mixing them corrupts the .dart_tool hook cache —
  always use the 3.13.0 SDK for builds/tests.
- Harness fixes this session (a39713f): reply injection waits for the
  dart build to finish (cold builds otherwise eat the injection and the
  app hangs at init); tina_sweep_task's approve loop no longer dies on
  the first approval (unbound last_approval/stuck under set -u) and
  tolerates a non-matching approval grep; new tool/corpus_sweep.sh runs
  a full pass at one geometry with per-task pane captures + fixture
  reset.
- The fixture's parent repo is visible to the corpus agents (task-sheet
  isolation doesn't hold); sweep_tasks.md and docs were safe this pass.
