---
id: tin-p8k2
status: closed
deps: []
links: [tin-q4vz, tin-b4n7]
created: 2026-08-17T11:20:00Z
closed: 2026-08-18T00:35:00Z
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
multi-cell damage as an unaddressed space RUN chained onto the row's content
run. When that content carries a cluster, tmux's grid is already drifted
right by (tmux_w − nc_w) cells, so the run's tail wraps one or more cells
onto the next screen row — blanking its border column.

## Repro (deterministic — see below)

Live: 1 in ~3 runs, `tool/q4vz_live.sh` with `BODY=/tmp/paste_ascii.txt`
and the stub on `emoji_cjk`. Raw-stream evidence
(`/tmp/q4vz_live/fixed_ascii/raw_copy.log`): after the cluster content run,
`\x1b[39m` + 86 unaddressed spaces, then `\x1b[37;2H` + 117 spaces
(addressed, harmless). The chained run ends 9 cells past the pane edge in
tmux's grid; its tail lands on (row+1, col 1), over the `│` border. nc's
retained grid calls that border cell undamaged, so repaints never restore
it.

**Deterministic:** `tool/p8k2_check.sh` (driver `tool/p8k2_repro.dart` +
oracle `tool/p8k2_check.dart`). The repro drives the real
NotcursesBackend+Screen+PanelFrame+ScrollingTextRegion stack in a tmux
pane: fill the chat with full-width wrapped rows (unbroken tokens, ending
with an exact-width-multiple line), then append one short ZWJ-cluster row —
it lands on the visual row that held a full-width row. The checker replays
the captured pane byte stream through the test-suite `VirtualTerminal`
(tmux-class widths + deferred autowrap) and asserts every content row keeps
both borders. Pre-fix: 2 borderless rows, stable across runs (the cluster
row's right border + the next row's left border). Post-fix: 38/38 intact,
stable.

Solid-x filler matters: a '047 047' style filler leaves matching space cells
undamaged, nc re-addresses around them, and no run chains.

## Root cause correction (supersedes the original "fix direction")

The original primary candidate — bounding our pre-erase span — is
**insufficient**: the 86-space run is RASTER DAMAGE (the previous frame's
row filled the plane to its last column; those cells must go blank), so its
length is set by the previous frame's extent, not by our pre-erase length.
Any cluster-bearing row that replaces a longer row spills by exactly its
drift, regardless of what we hand nc.

What does fix it: never let ONE raster contain cluster-content + trailing
erase as contiguous damage. `NotcursesBackendSurface.putAt` now erases
first, and when the incoming text is drift-bearing
(`driftsAgainstRaster`, term_width.dart — ZWJ present) forces
`_platform.render()` BEFORE writing the content. The erase raster emits
ADDRESSED runs (a CUP sequence is absolute — cursor drift is irrelevant);
the content raster that follows carries only the text, which never exceeds
the column budget. Chaining becomes impossible; drift has nothing to
displace.

`clearCells` (the bounded pre-erase) is still in the fix — it keeps the
erase span honest (previous painted extent via the caller's snapshot,
`_emitRow` passes `_visibleLen(previous)` / the styled-diff old-tail width)
and skips the pre-erase entirely when the new text already covers the old
extent — but it is hygiene, not the cure.

Also fixed in passing: the erase skip removes the spurious full-budget
space write under growing rows (less raster damage per streaming append).

## Acceptance

- Deterministic repro at the raster level: `tool/p8k2_check.sh` — real
  notcurses raster, real tmux pane, tmux-class VT oracle. Passes.
- Caller-half regression in `dart test`: chat_native_scroll_test.dart
  'erase span reporting (tin-p8k2)' — first paint reports null, styled
  tail patch reports the old-tail width (2 for the CD→CDEF run), same-
  geometry rewrite reports the previous painted extent (5 for 'hello'),
  never the full budget.
- Suites: root 543/543, tina_console 739/739 (736 + 3 new).
- Live: 4/4 runs at 0 borderless — 3× `BODY=/tmp/paste_ascii.txt` +
  1× `BODY=/tmp/paste5k.txt`, stub on emoji_cjk
  (/tmp/q4vz_live/livefix1..4).

## Postscript

Building the repro surfaced **tin-b4n7** ('\n'-terminated write into a full
buffer leaves the new row unrendered — stale pending-row index after the
coalesced scroll). The repro routes around it (reply written without a
trailing newline); the defect is real and ticketed separately.
