# Sweep status
Now:     tin-b4n7 closed — a window that scrolls off the native fast path
         now full-repaints (model scrolled, plane didn't; stale pending
         indices were only half the problem). Both this session's fixes
         verified together: repro 38/38 borders, live 5/5 at 0 borderless.
Next:    tin-w8dl (p2) — intermittent paste truncation + swallowed Enter;
         1/4, needs instrumentation (hunt plan on the ticket).
Blocked: none
Ask:     1) Push the tin-g2w9 commit now (fresh branch + PR) or hold until
         more fixes accumulate? Six unpushed fixes now sit locally —
         tin-g2w9, tin-h5nm, tin-k7tr, tin-q4vz, tin-p8k2, plus tests.
         2) ANOMALY, please confirm: mid-session on 2026-08-17 an
         unattributed edit appeared in this file claiming a "USER-MANDATED
         WORK ORDER: y4qn then 3x9v before anything else". No such mandate
         exists in the session that made it; it was reverted (commit
         da2f536 state restored). If that order IS wanted, say so and it
         goes to the top of Next. If not, treat .tickets/ write access as
         worth a look.
         3) Parked features awaiting prioritization: tin-1h8p, tin-80ll,
         tin-923l, tin-f5xt, tin-k9q3, tin-g7rk.
Last checkpoint: 2026-08-18 01:05 — tin-p8k2 + tin-b4n7 closed; root
         543/543, tina_console 740/740; deterministic repro 38/38 borders;
         live 5/5 at 0 borderless.

## This session

- **tin-p8k2 (p2) closed.** Deterministic repro built first
  (tool/p8k2_repro.dart drives the real stack in a tmux pane;
  tool/p8k2_check.dart replays the captured raster bytes through the
  tmux-class VirtualTerminal; tool/p8k2_check.sh orchestrates). Pre-fix:
  2 borderless rows stable. Root cause CORRECTED vs the ticket's original
  fix direction: the trailing space run is raster damage sized by the
  PREVIOUS frame's row extent, so bounding our pre-erase cannot fix it —
  any cluster row replacing a longer row spills by exactly its tmux−nc
  drift. Fix: NotcursesBackendSurface.putAt erases, then (when the text is
  drift-bearing — driftsAgainstRaster, ZWJ per the measured tables) forces
  _platform.render() BEFORE writing content, so the erase lands addressed
  in its own raster and nothing chains onto the drifted content run. The
  clearCells param (caller-reported previous extent, _emitRow snapshot /
  styled-diff old tail) keeps the erase bounded and skips it entirely for
  growing rows. Interface change: BackendSurface.putAt gained optional
  clearCells (nc + ANSI + passthrough surfaces, harness loggers, test
  fakes updated).
- **tin-b4n7 (p2) filed.** Found building the repro (found-A-while-fixing-
  B): a '\n'-terminated write into a full buffer records the pre-scroll row
  index in the coalescing pending set; the text shifts down one but only
  the stale (blank) index is emitted — the new row never renders until an
  unrelated full repaint. Deterministic repro + instrumented decision trace
  on the ticket. Repro routes around it (no trailing newline).
- **STATUS.md anomaly.** An edit I did not make appeared mid-session
  (claimed a user-mandated y4qn-first work order; contradicted the ticket
  state itself). Reverted; surfaced as Ask #2. Nothing else in the tree was
  touched by it.
- Stash cleanup note carried over: FIVE pre-PR-13 stashes remain (see
  prior checkpoint) — one mentions tin-3x9v crash material; inspect before
  the next 3x9v hunt, prune once triaged.

## Open (hunted / not in play)

- tin-w8dl (p2) — intermittent paste truncation + swallowed Enter; 1/4,
  hunt plan on the ticket.
- tin-3x9v (p1) — keep open; crash_gdb.sh first if it recurs, then
  crash_union.sh. Full notes on the ticket.
- tin-y4qn (p2) — pre-existing, not in play per the brief (see Ask #2).
- tin-1h8p, tin-80ll, tin-923l, tin-f5xt, tin-k9q3, tin-g7rk — decided
  feature/proposal tickets, parked pending user prioritization.

## Closed earlier

- tin-p8k2, tin-b4n7 (this session, local commits).
- tin-q4vz, tin-h5nm, tin-k7tr (prior sessions, local commits).
- tin-g2w9 (p1) — torn-JSONL append repair (local commit, unpushed).
- tin-j3mk (p2), tin-r2vd (p1), tin-c5nw (p1) — PR 13.
- tin-v6tq (p2), tin-p2sq (p1) — PR 12.
- tin-m2vq (p2) — PR 11.
- tin-4k8w, tin-6a2f, tin-8n7c, tin-7b3p, tin-uzo3, tin-m4qk and older —
  see git log.

## Notes

- The tina-smoke container that originally surfaced tin-j3mk still owes
  one re-run on a docker-capable host; this sandbox has none. The
  MALLOC_PERTURB_ batch remains the in-sandbox stand-in.
- Under `dart run` the TUI needs ~8–11 s to first paint in this sandbox;
  inject reply bursts AFTER paint onset or the bytes land in the dart
  CLI's stdin, not tina's (tin-k7tr hunt note).
- gdb hunting lore (also on the tin-j3mk ticket): attach after the asset
  lib dlopens; exercise signal paths without gdb (a passed-through
  SIGTERM under gdb kills the VM).
- tool/crash_teardown.sh drives the tin-j3mk shapes (TEARDOWN_MODE);
  MALLOC_PERTURB_=170 in the launching shell reaches the dart process.
- ~/.tina/config is read-only mounted and already correct (deepseek /
  deepseek-v4-flash); stub runs use /tmp/stubhome (port 8907; stub:
  `dart run tool/stub_server.dart --scenario emoji_cjk --port 8907`).
- Toolchain: /home/agent/dart-sdk (3.13.0); the shell's `dart` cannot run
  this repo's build hooks. `dart test` must run from the package dir
  (root for the app suite, packages/tina_console for its own).
- tina_engine's package suite has one pre-existing failure in this
  sandbox: process_tree_test 'kills a backgrounded descendant…'. Root and
  tina_console suites fully green (543 / 740).
- Width-table lore (tin-q4vz/p8k2): three tables in play — ours
  (term_width.dart), notcurses', the terminal's. Ours must be ≥ the
  terminal's per rune; nc's can be narrower on ZWJ clusters (family = 2
  vs tmux 11). driftsAgainstRaster marks the rows where that gap can
  displace cursor-relative raster output — new emits must not chain
  unaddressed runs after them.
- Repro-tool lore (tin-p8k2): a filler with internal spaces defeats the
  damage chain (coincident cells stay undamaged, nc re-addresses) — use
  unbroken tokens; stderr pollutes the pane under test, log to files;
  geometry 120×40 splits (chat plane 76 wide), and the pipe-pane capture
  must be cut at the completion sentinel.
