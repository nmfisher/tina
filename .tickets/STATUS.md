# Sweep status
Now:     Ticket sweep — no code changes. tin-k7f2 closed (Phase 1 landed
         via PR #53; all six review defects fixed with regression tests,
         verified on main). tin-1h8p, tin-80ll, tin-923l, tin-9x4m,
         tin-f5xt, tin-k9q3 closed: all six were implemented and merged
         weeks ago (PRs #31–#35, #52) but their frontmatter still read
         the nonstandard `done` and this file still called them parked.
         Every ticket now carries `open | start | closed` only; STATUS.md
         no longer invents statuses.
Next:    Pick up tin-p4wm item 3 (`/spawn`+`/branch` drop configured
         static rules — smallest, has a crisp acceptance test), then
         tin-w7dr (needs the live wheel repro first). tin-r6km resumes
         at proposal P6–P8 + the PR #49 review fixes (P0–P5 review
         items 1–3 and 5–7 remain open on main).
Blocked: tin-r6km P8 is blocked on the review fixes; nothing else.
Ask:     tin-p4wm item 2 needs a posture decision: declaring
         `explore_project` a project read flips its default ask → allow.
Last checkpoint: 2026-09-22 — ticket sweep; STATUS.md rewritten.
         Previous (2026-09-20): mode-selector pair closed (see git).

## This session

- Ticket sweep only. Frontmatter normalized (7 files), tin-k7f2's
  REOPENED note resolved to closed-with-evidence, this file rewritten.

## Open

- tin-p4wm (p1) — permission hardening: write_summary spawns outside
  the framework; explore_project read-only-but-undeclared (needs a
  decision); /spawn + /branch drop the user's configured static rules.
  Adjacent (separate decision): LocalControlTool bypasses check();
  auto-mode classifier substring parse can grant on DENY.
- tin-r6km (p2) — plugin runtime, status: start. PR #49 merged P0–P5
  partially; docs/proposals/plugin_runtime_pr49_fixes.md is the live
  punch list (contribution wiring into production consumers, driver
  replacement across all entry points, awaited rollback, argument
  sealing); P6–P8 not started. Later phase commits
  (describe()/profile, docs) live on side branches, not main.
- tin-w7dr (p1) — mouse wheel while an approval pends duplicate-prints
  the approval prompt. Not yet reproduced; first job is the live repro
  (three named suspects in the ticket).

## Closed earlier

- tin-k7f2 (p1) — PTY backend Phase 1, PR #53 (a3f008e, 2026-09-16) +
  six review-fix commits e9b7f64, cdab3d6, 14970de, 92758fd, 147c1f7,
  cf31087; regression tests in
  packages/tina_engine/test/terminal/ (incl. pty_reap_test.dart).
- tin-p4wm filed 1c2bbaa (2026-09-21). tin-k4m8 + tin-q9w2 — PR #55
  (894a4cc, 2026-09-20). --yolo budget lift — PR #56 (36643a4).
- tin-9x4m — PR #52 (#31), 2026-08-23. tin-1h8p — PR #32, 2026-08-25.
  tin-80ll + tin-923l — PR #33, 2026-08-26 (923l superseded by 80ll).
  tin-f5xt — PR #34, 2026-08-27. tin-k9q3 — PR #35, 2026-08-29.
- tin-g7rk (p2) — asb/markdown-render PR (2026-08-22).
- tin-y4qn, tin-w8dl, tin-p8k2, tin-b4n7, tin-q4vz, tin-h5nm, tin-k7tr,
  tin-g2w9, tin-3x9v (CNR) — PR #14.
- tin-j3mk (p2), tin-r2vd (p1), tin-c5nw (p1) — PR 13.
- tin-v6tq (p2), tin-p2sq (p1) — PR 12.
- tin-m2vq (p2) — PR 11.
- tin-8n7c — PRs 8 + 10. tin-7b3p — PR 8.
- tin-4k8w, tin-6a2f — PR 9.
- tin-h8uw, tin-vb4k — PRs 6/7.
- tin-9zqx, tin-x4m7, tin-uzo3, tin-m4qk, tin-7spm and older — see
  git log.

## Notes

- Root `dart analyze` has pre-existing errors in tool/render_to_image.dart
  and tool/visual_test.dart (reference tina_console panel_layout/
  panel_renderer modules that don't exist; untouched since the initial
  release).
- tina_engine's package suite has one pre-existing failure in this sandbox:
  process_tree_test 'kills a backgrounded descendant…'. Root and
  tina_console suites fully green. Probed 2026-08-23: spawned
  grandchildren live in a PID namespace the VM can't signal — pgrep
  (subprocess) sees them, the VM's own /proc doesn't, so SIGKILL lands on
  the wrong pid. Sandbox-only; the code is sound.
- bash_tool_test 'output above the cap keeps the tail and spills the full
  output' flakes ~1/12 in isolation: it asserts `isNot(contains('A'))`
  while the spill path embeds the random createTemp suffix
  (tina_bash_test_<random>), which can itself contain 'A'. Random-name
  collision, not a tail-keep regression; fix would be a deterministic
  spill-path assert.
- Stub lore: /tmp/stubhome carries the canonical stub config; a pristine
  copy lives at /tmp/w8dl_hunt/stub.config. tool/w8dl_hunt.sh and
  tool/y4qn_hunt.sh (re)start the stub per invocation — kill leftover
  stubs between sessions or they hold the port.
- Paste-path audit lore: set TINA_PASTE_AUDIT_LOG=<file> in the tina env;
  log lines are `w8dl <ms> ...`. Counts are UTF-16 units, not runes. The
  hunt wrapper can hang at exit holding the stub as a child (do_wait) —
  kill the wrapper, not the stub.
- Width-table lore (tin-q4vz/p8k2): three tables in play — ours
  (term_width.dart), notcurses', the terminal's. Ours must be ≥ the
  terminal's per rune. driftsAgainstRaster marks the rows where that gap
  can displace cursor-relative raster output — new emits must not chain
  unaddressed runs after them.
- Repro-tool lore (tin-p8k2): a filler with internal spaces defeats the
  damage chain — use unbroken tokens; stderr pollutes the pane under test;
  geometry 120×40 splits (chat plane 76 wide), and the pipe-pane capture
  must be cut at the completion sentinel.
- Re-open condition (tin-3x9v): any native SIGSEGV — tool/crash_gdb.sh
  first, then tool/crash_union.sh.
- tin-k7f2 follow-ups, not defects: Phase 1 verified on Linux x64 only
  (macOS/arm64 builds from the same C but is unverified); the crash-hunt
  harnesses under tool/ (tin-3x9v etc.) are the standing regression
  probes for the native layer the PTY work now shares.
