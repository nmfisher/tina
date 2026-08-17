# Sweep status
Now:     tin-q4vz closed — terminal-cell width accounting at every emit
         budget (term_width.dart, err-high doctrine); corpus clean live.
Next:    tin-p8k2 (p2, new): residual 1-cell borderless row from an nc
         raster erase run after ZWJ-cluster drift — fix direction on the
         ticket (shrink the surface pre-erase span). tin-w8dl (p2) still
         needs instrumentation — no deterministic repro yet.
Blocked: none
Ask:     Parked features awaiting prioritization: tin-1h8p, tin-80ll,
         tin-923l, tin-f5xt, tin-k9q3, tin-g7rk. Also: push the tin-g2w9
         commit now (fresh branch + PR) or hold until more fixes
         accumulate? (carried over; five unpushed fixes now sit locally —
         tin-g2w9, tin-h5nm, tin-k7tr, tin-q4vz, plus tests.)
Last checkpoint: 2026-08-17 11:30 — tin-q4vz closed; root 543/543,
         tina_console 736/736; live repro 0 borderless ×3 runs.

## This session

- **tin-q4vz (p2) closed.** Paste-content rows lost the left border; one
  wide-char row also dropped a glyph (`long-token:` → ` long-toke :`).
  Root (hunt 2): every column budget counted 1 column per UTF-16 code
  unit, so a wide/ZWJ row's budget was honest per OUR table but wider per
  the real terminal's — the rasterized run autowrapped past the pane edge
  onto the next screen row, blanking the border and the first cells of the
  row below; nc's retained grid considered those cells undamaged, so it
  survived repaints. Fix (hunt 3): `term_width.dart` — one conservative
  cell table (wide 2, combining 0, VS16 1, ZWJ 1 per live tmux
  measurement, astral 2; err high, never low) applied at every budget
  site: `_writeInternal` wrap (wide rune with no room now wraps, pairs
  never split), `_visibleLen` + both bar-pad sites (pad to width−1 so a
  full row can't invite the raster's autowrap continuation),
  `clipToVisibleColumns`, `_emitSgrStyled`/walker run advance,
  `diffStyledRuns` colOffset + oldTailWidth, `visibleColumns`,
  `_appendToRow`. VT harness now models tmux-class widths so corpus tests
  can actually catch autowrap. Salvaged the prior session's stashed WIP
  (its width-aware VT + edge-panel test; its lib half referenced a
  terminal_width.dart it never created — superseded by ours).
- **tin-p8k2 (p2) filed.** Found verifying q4vz: 1-in-3 runs, ASCII paste
  + emoji_cjk reply, one blank row loses its left border. The nc RASTER
  emits a multi-cell erase as an unaddressed space run that relies on
  autowrap to cross a row boundary; tmux's ZWJ-cluster layout is 9 cells
  wider than nc's, so the run's tail wraps onto the next row's col 1.
  Below our budget layer (our writes were in-budget). Fix direction:
  replace `NotcursesBackendSurface.putAt`'s unconditional `' ' * maxCols`
  pre-erase with a caller-supplied old-tail span.
- Stash cleanup: dropped the three prior-session WIP stashes (all were
  mid-compaction q4vz attempts; the useful parts are in this commit).
  Check `git stash list` is empty if resuming.

## Open (hunted / not in play)

- tin-p8k2 (p2) — residual nc-raster autowrap spill; new, next up.
- tin-w8dl (p2) — intermittent paste truncation + swallowed Enter; 1/4,
  hunt plan on the ticket.
- tin-3x9v (p1) — keep open; crash_gdb.sh first if it recurs, then
  crash_union.sh. Full notes on the ticket.
- tin-y4qn (p2) — pre-existing, not in play per the brief.
- tin-1h8p, tin-80ll, tin-923l, tin-f5xt, tin-k9q3 — decided
  feature/proposal tickets from prior sessions, parked pending user
  prioritization.

## Closed earlier

- tin-q4vz (this session, local commit).
- tin-h5nm, tin-k7tr (prior session, local commits).
- tin-g2w9 (p1) — torn-JSONL append repair (local commit, unpushed).
- tin-j3mk (p2) — teardown UAF: input pump joined before notcurses_stop
  on every stop path (in PR 13).
- tin-r2vd (p1) — notcurses init wait bounded for mute terminals (PR 13).
- tin-c5nw (p1) — global shortcuts cycle panels while an approval is
  open (PR 13).
- tin-v6tq (p2), tin-p2sq (p1) — PR 12.
- tin-m2vq (p2) — PR 11.
- tin-4k8w, tin-6a2f, tin-8n7c, tin-7b3p, tin-uzo3, tin-m4qk and older —
  see git log.

## Notes

- The tina-smoke container that originally surfaced tin-j3mk still owes
  one re-run on a docker-capable host; this sandbox has none. The
  MALLOC_PERTURB_ batch remains the in-sandbox stand-in.
- Under `dart run` the TUI needs ~8–11 s to first paint in this sandbox;
  when injecting reply bursts (tmux_inject_replies.sh), inject AFTER
  paint onset or the bytes land in the dart CLI's stdin, not tina's
  (tin-k7tr hunt note).
- gdb hunting lore (also on the tin-j3mk ticket): attach after the asset
  lib dlopens — pending breakpoints never resolve under `dart run`; a
  passed-through SIGTERM under an attached gdb kills the VM instead of
  reaching Dart's watcher, so exercise signal paths without gdb.
- `tool/crash_teardown.sh` drives the tin-j3mk shapes: TEARDOWN_MODE =
  term-burst | term-flood | term-idle | quit-burst. MALLOC_PERTURB_=170
  in the launching shell reaches the dart process (tmux server restarts
  per run and inherits it).
- ~/.tina/config is read-only mounted and already correct (deepseek /
  deepseek-v4-flash); stub runs use a fresh HOME with the stub config
  (port 8907 this session; stub: `dart run tool/stub_server.dart
  --scenario emoji_cjk --port 8907`).
- Toolchain: /home/agent/dart-sdk (3.13.0) for all builds/tests; the
  shell's `dart` cannot run this repo's build hooks.
- tina_engine's package suite has one pre-existing failure in this
  sandbox: process_tree_test 'kills a backgrounded descendant…'. Root
  and tina_console suites are fully green (543 / 736).
- Width-table lore (tin-q4vz/p8k2): three tables in play — ours
  (term_width.dart), notcurses', the terminal's. Ours must be ≥ the
  terminal's per rune (errs high); nc's can be narrower on ZWJ clusters
  (family = 2 vs tmux 11), which is what feeds tin-p8k2.
