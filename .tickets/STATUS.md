# Sweep status

Now:     tin-8n7c — approval keys vanish at steady cadence (open; stale-paste auto-deny part fixed)
Next:    tin-6a2f (p2, approval line overlap), corpus T7/T8/T11/T4/T13/T9/T12/T15/T14 + second geometry
Blocked: none
Ask:     none
Last checkpoint: 2026-08-15 16:00 — 2 closed (tin-7b3p, tin-8n7c part), 3 open filed this session, suites green (root +538, tina_console +670)

## Session log

- Harness rebuilt from scratch: the vendored notcurses 3.0.17 input automaton
  cannot parse tmux's DA1 reply `\e[?1;2;4c` (numeric-trie collision — proven
  with a unit test against the automaton), and `tmux send-keys -H` delivers
  nothing on tmux 3.4. The working harness: inject replies via `send-keys`
  named keys (Escape / literals / `\;`), including a matchable DA1
  (`\e[?62;c`). Scripts saved: `tool/tmux_inject_replies.sh`,
  `tool/tina_sweep_run.sh`, `tool/tina_sweep_task.sh`.
- Corpus so far (120×40, real deepseek provider): T1 PASS (answer correct;
  raw markdown = known tin-g7rk), T2 PASS, T3 PASS (diff preview renders
  red/green; single-file rename justified), T6 PASS (read output not shown
  inline — CJK never hit the screen), T10 PASS (CJK title `决定缓存过期策略`
  renders correctly; 4 open tasks correct), T11 PARTIAL (long-line read; the
  tool-output truncation indicator `… (N more chars — /output)` renders).
- T5 start: environment-agent first-load ceremony churns many approvals
  (fixture was reset, ENVIRONMENT.md removed by `example_workspace.sh
  reset`); ceremony approved through.
- Environment agent behavior: first-load ceremony per repo; ENVIRONMENT.md
  written into the fixture (clean, no secrets); warm load is quiet.
  ENVIRONMENT.md currently absent (reset) → ceremony runs on each fresh
  launch.
- One-off TUI segfault mid-run at a pending approval (2026-08-15, one
  occurrence, not reproduced; adjacent to tin-j3mk teardown segfault — not
  re-filed).
- Loading-border gradient animation observed during agent turns (tin-y4qn
  scope — already filed).
- Tickets filed this session: tin-6a2f (approval line overlap under rapid
  approvals), tin-8n7c (approval input: stale-paste auto-deny + steady-cadence
  vanish), tin-7b3p (flaky root test — CLOSED).

## Closed

- tin-7b3p — root suite flaky regression test (fixed the test; root suite +538).
- tin-8n7c — stale-paste auto-deny part (fix 21af54e + regression test; the
  steady-cadence vanish remains open on the same ticket).

## Open (this sweep)

- tin-8n7c (p2) — approval keys vanish at steady cadence (input pump?).
- tin-6a2f (p2) — second approval's text merges onto the first's prompt line.
