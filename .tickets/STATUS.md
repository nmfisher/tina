# Sweep status
Now:     asb/mode-selector ready for PR — tin-k4m8 (Shift+Tab scrollback
         announce) + tin-q9w2 (mode strip never visible) fixed as separate
         commits; root 911 green, tina_console 916 green, analyze clean.
Next:    Raise PR for asb/mode-selector. Then tin-9x4m (p3, /spawn picker
         empty for custom providers) or a fresh probe batch from the
         scenario-seeds list.
Blocked: none
Ask:     1) Parked features awaiting prioritization: tin-1h8p, tin-80ll
         (+ its superseded sibling tin-923l), tin-f5xt, tin-k9q3.
Last checkpoint: 2026-09-20 — mode-selector pair closed (see This
         session). Previous checkpoint (2026-08-23): PR 17
         merge-conflict resolution pushed; bash_tool spill-test flake
         root-caused and logged. (2026-08-22): tin-g7rk closed; STATUS
         rewritten; dart-sdk toolchain note corrected.

## This session

- tin-k4m8 (25fb0c2) — Shift+Tab cycling no longer prints a
  `permission mode:` line into the scrollback; the strip label is the
  announcement. Pinned cycling tests rewritten to assert the ring flips
  `app.policy.mode` AND absence of the line in `io.written`. The
  /permissions command message is untouched (explicit command, not a
  keypress echo).
- tin-q9w2 — mode label now visible from the FIRST frame and never
  scrolls away. Root cause proven by probe: full-width layouts gave the
  strip row h-2 while the panel box's inputRect claimed the same row, so
  first paint's input erase wiped the label; create()'s startup paint was
  pre-alt-screen and never presented at all. Layout half fixed in
  tina_console a9905a9 (uniform rule: boxes stop above stripRow h-1) +
  3391a63 (strip re-asserts itself on colliding writes). App half in
  57ac02e: startup setModeLabel moved into run() after
  _refreshSessionMenu (joins first paint); panel_manager parked-panel
  virtual slots moved strictly below the visible stack (old slot*perPanel
  folded onto the last visible panel once the box shrank a row — caught
  by the panel_manager suite, not by a test authored for it).
- Regression coverage: coordinator tests decode the session's output
  through VirtualTerminal and assert 'mode: ask' sits on the strip row
  from the first frame, on exactly one grid row, never in the scrollback;
  and that it survives /clear, a mid-stream StreamNotice landing on the
  strip (setErrorStrip) and the next turn boundary (clearErrorStrip).
  Not automatable here: resize/side-panel-toggle survival remains
  manual-verification surface (subpackage strip tests cover the
  mechanics).
- Tree health: packages/*/.dart_tool absent in a fresh checkout breaks
  the architecture test + fake_async suite with confusing errors; a
  `dart pub get` per subpackage fixes it (dart_notcurses needs its
  submodule + online pub). pubspec.lock churn from those runs was
  reverted, not committed.

## Open (hunted / not in play)

- tin-9x4m (p3) — /spawn picker empty for custom providers.
- tin-1h8p, tin-80ll, tin-923l, tin-f5xt, tin-k9q3 — decided
  feature/proposal tickets, parked pending user prioritization.

## Closed this branch

- tin-k4m8 (p1), tin-q9w2 (p1) — asb/mode-selector, commits 25fb0c2 +
  57ac02e (plus tina_console a9905a9 + 3391a63), PR pending.

## Closed earlier

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

- The tina-smoke container that originally surfaced tin-j3mk still owes
  one re-run on a docker-capable host; this sandbox has none. The
  MALLOC_PERTURB_ batch remains the in-sandbox stand-in.
- Under `dart run` the TUI needs ~8–11 s to first paint in this sandbox;
  inject reply bursts AFTER paint onset or the bytes land in the dart
  CLI's stdin, not tina's (tin-k7tr hunt note).
- Toolchain: /opt/dart-sdk (3.13.1) on PATH; initialize the
  dart_notcurses submodule before `dart pub get`. `dart test` must run
  from the package dir (root for the app suite, packages/tina_console
  for its own).
- Root `dart analyze` has pre-existing errors in tool/render_to_image.dart
  and tool/visual_test.dart (reference tina_console panel_layout/
  panel_renderer modules that don't exist; untouched since the initial
  release) — not introduced by and not blocking the g7rk work.
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
