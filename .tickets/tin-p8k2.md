---
id: tin-p8k2
status: open
deps: []
links: [tin-q4vz]
created: 2026-08-17T11:20:00Z
type: bug
priority: 2
assignee: Nick Fisher
tags: [tui, chat-panel, rendering, notcurses, zwj]
---
# Residual 1-cell borderless blank row from a notcurses raster erase run after ZWJ-cluster drift

## Context

Found while verifying the tin-q4vz fix (filed per found-A-while-fixing-B).
The q4vz layer — our own column budgets — is fixed and the paste corpus is
clean. What remains is one layer lower: notcurses' raster ↔ tmux's width
table disagree on ZWJ clusters (nc composes 👨‍👩‍👧‍👦 to 2 cells; tmux lays
the same cluster out 11 — hunt 2's measurement), and nc's raster emits
multi-cell damage as an unaddressed space RUN that relies on the terminal's
autowrap to cross a row boundary. When the run follows cluster-bearing
content, tmux's grid is already drifted right by (tmux_w − nc_w) cells, so
the run's tail wraps one or more cells onto the next screen row — blanking
its border column (and, with enough drift, its first content cells).

## Repro (1 in ~3 runs, needs family-cluster prose in the chat)

1. `tool/q4vz_live.sh` with `BODY=/tmp/paste_ascii.txt` (ASCII paste) and
   the stub on the `emoji_cjk` scenario — the reply's ZWJ line is the
   trigger. Observed: 1 borderless row (blank, right border intact) where
   the reply row above contains `👨‍👩‍👧‍👦（一个 grapheme…`.
2. Same run with the CJK paste body: 0 borderless (3 runs total: 0, 0, 1).

Raw-stream evidence (`/tmp/q4vz_live/fixed_ascii/raw_copy.log`, idx ~45766):
nc addresses row 36, emits the content run (CJK + one family cluster), then
`\x1b[39m` + 86 spaces — a damage/erase run sized by NC's grid (nc content
≈ 60 cells wide where tmux lays ≈ 69+). In tmux's grid the run starts 9
cells right of where nc thinks it does, overruns col 120, and the last
space lands at (row+1, col 1) over the border. A layout simulation of the
byte stream with tmux-class widths confirms exactly one wrap-print, `' '`,
on the affected row.

## Why the q4vz fix can't cover it

Our writes to that row were within budget (row content ≤ plane width by the
term_width table, which matches tmux per-rune). The space run is generated
by nc's raster from ITS grid, spans the row boundary by design, and its
length is not something a caller controls. Any row whose tmux-width exceeds
its nc-width (≥ 1 ZWJ cluster, drift ≥ 9) can spill when nc chains an erase
across the boundary.

## Fix direction

- Primary candidate: shrink the erase we hand nc —
  `NotcursesBackendSurface.putAt` pre-erases `' ' * maxCols` on every put
  (full-width space run into the plane, which the raster then has to
  emit). Replacing the unconditional pre-erase with a caller-supplied
  `clearCells` span (old-tail width, the way the ANSI path's
  `patchStyledAtAbsolute` already does) bounds the run by the previous
  content instead of the plane width. Needs a snapshot of the row's
  previous width at the `_emitRow` layer (paintedWidth is already tracked).
- Alternative if that's insufficient: reserve right-edge slack
  proportional to cluster count in the row budget (drift ≤ our_w − nc_w ≈
  our_w − 2·clusters), i.e. wrap earlier on cluster-heavy rows so the
  drifted run still ends ≤ col 120. Cruder; costs columns on every wide
  row.
- Not ours: fixing nc's table or raster (upstream).

## Acceptance

- A deterministic repro at the notcurses-backend level (recording fake is
  not enough — needs the raster; drive via `tool/q4vz_live.sh`-style live
  runs, or `render_to_image` harness with cluster content).
- Live: 3/3 runs at 0 borderless with the emoji_cjk reply in play.
