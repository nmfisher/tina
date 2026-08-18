# Sweep status
Now:     All local work is PUSHED — PR #14 (d135b9d, merged 2026-08-18
         11:08) carried the eight formerly-unpushed fixes (tin-g2w9,
         tin-h5nm, tin-k7tr, tin-q4vz, tin-p8k2, tin-b4n7, tin-w8dl,
         tin-y4qn) plus the tin-3x9v CNR closure and the tin-9x4m filing.
         main == origin/main; the only untracked path is .claude/.
         Ticket audit (2026-08-18, this session): all 35 tickets reviewed
         against the tree — stale pre-repackage test paths corrected
         (q4vz/p8k2/k7tr/v6tq/w8dl/k9q3 now cite packages/tina_console
         and packages/tina_engine locations), dangling pre-squash fix
         SHAs annotated with their landing PRs (8n7c→#8/#10, 4k8w→#9,
         6a2f→#9, 7b3p→#8), 923l cross-linked to its superseding
         decision 80ll. tin-3x9v's stash SHAs are intentionally-dangling
         (dropped after triage; recorded on the ticket).
Next:    tin-9x4m (p3, /spawn picker empty for custom providers) or a fresh
         probe batch from the scenario-seeds list. No open bug tickets
         otherwise.
Blocked: none
Ask:     1) Parked features awaiting prioritization: tin-1h8p, tin-80ll
         (+ its superseded sibling tin-923l), tin-f5xt, tin-k9q3,
         tin-g7rk.
Last checkpoint: 2026-08-18 — PR #14 confirmed landed; ticket audit
         applied (path fixes, SHA annotations, cross-links); STATUS
         rewritten. Previous checkpoint (03:30): tin-y4qn closed,
         tin-3x9v closed CNR, stashes pruned.

## This session

- Ticket audit only — no product code touched:
  - Verified PR #14 contains all eight fixes STATUS previously listed
    as unpushed; old Ask #1 (push vs accumulate) is resolved.
  - Corrected six tickets' test-path citations to the post-repackage
    layout (root `test/…` → `packages/tina_console/test/…`,
    `packages/tina_engine/test/…`).
  - Annotated dangling fix SHAs with the squash-merge PR that carried
    each (verified via `git log -S` on the regression tests).
  - tin-923l: added links + supersession note re tin-80ll.
  - Confirmed the seven open tickets' code references still resolve
    (spawn_overlay.dart, session_commands/, sandbox_runner, no markdown
    pkg) and the y4qn regression test exists
    (test/tui/panel_busy_cue_test.dart).

## Open (hunted / not in play)

- tin-9x4m (p3) — /spawn picker empty for custom providers.
- tin-1h8p, tin-80ll, tin-923l, tin-f5xt, tin-k9q3, tin-g7rk — decided
  feature/proposal tickets, parked pending user prioritization.

## Closed earlier

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

- The tina-smoke container that originally surfaced tin-j3mk still owes
  one re-run on a docker-capable host; this sandbox has none. The
  MALLOC_PERTURB_ batch remains the in-sandbox stand-in.
- Under `dart run` the TUI needs ~8–11 s to first paint in this sandbox;
  inject reply bursts AFTER paint onset or the bytes land in the dart
  CLI's stdin, not tina's (tin-k7tr hunt note).
- Toolchain: /home/agent/dart-sdk (3.13.0); the shell's `dart` cannot run
  this repo's build hooks. `dart test` must run from the package dir
  (root for the app suite, packages/tina_console for its own).
- tina_engine's package suite has one pre-existing failure in this sandbox:
  process_tree_test 'kills a backgrounded descendant…'. Root and
  tina_console suites fully green.
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
