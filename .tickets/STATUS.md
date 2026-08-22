# Sweep status
Now:     tin-g7rk (p2, markdown rendering in the TUI) implemented on branch
         asb/markdown-render — renderer + sink integration + Ctrl+R raw
         view; all suites green (root 719, tina_console 789, engine 728 +
         the known sandbox failure). Ticket closed with a full resolution
         record; PR raised against main, NOT merged.
Next:    Review/merge the tin-g7rk PR. Then tin-9x4m (p3, /spawn picker
         empty for custom providers) or a fresh probe batch from the
         scenario-seeds list.
Blocked: none
Ask:     1) Parked features awaiting prioritization: tin-1h8p, tin-80ll
         (+ its superseded sibling tin-923l), tin-f5xt, tin-k9q3.
Last checkpoint: 2026-08-22 — tin-g7rk closed (markdown rendering +
         raw view, PR pending); STATUS rewritten; dart-sdk toolchain note
         corrected. Previous checkpoint (2026-08-18): PR #14 confirmed
         landed; ticket audit applied (path fixes, SHA annotations,
         cross-links).

## This session

- tin-g7rk end to end on asb/markdown-render:
  - ChatTheme gained header/inlineCode/codeBlock/link fields
    (default/light/dark), vocabulary-pinned by tests.
  - lib/tui/markdown_renderer.dart: pure renderer (markdown pkg 7.3.1,
    app-level dep only) + MarkdownStreamSplitter (block-granularity
    streaming contract).
  - ChatAgentSink renders closed blocks (flush on newline/toolStart/
    notice); passthrough stays byte-exact; onRawText publishes the
    turn raw; beginAssistantTurn abandons it.
  - Ctrl+R (ControlCode.ctrlR, both input backends; LineEditor.onRawView
    at the maximize rank) opens the generic viewer with the active
    conversation's raw markdown. Default off.
  - panel_busy_cue's gate provider now streams a closed block — the
    mid-turn streaming observable under block-granularity rendering.
- Toolchain correction: dart is /opt/dart-sdk (3.13.1) on PATH — the old
  /home/agent/dart-sdk note was stale. dart_notcurses submodule must be
  initialized (`git submodule update --init packages/dart_notcurses`)
  before `dart pub get` works at root/tina_console.

## Open (hunted / not in play)

- tin-9x4m (p3) — /spawn picker empty for custom providers.
- tin-1h8p, tin-80ll, tin-923l, tin-f5xt, tin-k9q3 — decided
  feature/proposal tickets, parked pending user prioritization.

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
