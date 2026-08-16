---
id: tin-m2vq
status: closed
deps: []
links: [tin-4k8w, tin-3x9v]
created: 2026-08-16T09:55:00Z
type: bug
priority: 2
assignee: Nick Fisher
tags: [tui, render, resize, streaming, panels]
---
# Rapid resizes mid-stream merge two chat rows into one

## Context

Found 2026-08-16 during the tin-3x9v resize-storm hunt
(`tool/crash_resize.sh`): while a bash tool call streams one line every
0.35 s, resizing the pane through a grow/shrink cycle every 0.4 s leaves
two adjacent chat rows rendered without their line break — the boundary
row and the next row's text run together on one line:

```
│streamed line 28                                          │
│streamed line 29streamed line 30                          │   <-- merged
│streamed line 31                                          │
```

Both runs of the storm harness produced the merge at the same place
(rows 29/30), so it is deterministic for a given resize timing, not a
torn capture (a torn capture would land at a random row, and the row
above and below are intact).

A single controlled shrink (120×40 → 80×24 mid-stream, then 5 s settle)
renders cleanly — every row keeps its break. So the defect needs a
resize *storm*: the reconcile of one resize is interrupted by the next
before the full re-emission tin-4k8w added completes.

## Repro

1. Start the stub server with scenario `crash_stream2`
   (`dart run tool/stub_server.dart --scenario crash_stream2 --port 8907`)
   and prepare `/tmp/stubhome` (see `tool/crash_replyburst.sh`).
2. `tool/crash_resize.sh 2 /tmp/crash_resize` — each run submits the
   prompt, approves, then cycles 120×40 → 80×24 → 60×15 → 200×50 →
   80×24 → 120×40 every 0.4 s while the 42 s bash stream runs and `y`
   is pressed every 0.8 s.
3. Read the captured pane: `grep -nE 'streamed line [0-9]+[a-z]'
   /tmp/crash_resize/*.pane` — 2 matches in run 1, 1 in run 2, both at
   "line 29streamed line 30".

## Acceptance

- No two chat rows ever render merged, under any resize cadence.
- A regression test covers resize-while-appending at the row that lands
  on the panel boundary when a second resize arrives before the
  reconcile finishes.
- `tool/crash_resize.sh` panes show zero merged-row matches.

## Fix (2026-08-16, closed)

Root cause: `ScrollingTextRegion._reconcileRows()` sized the shrunk row
buffer to `bounds.height` and kept up to that many CONTENT rows, then
clamped `_curRow` onto the last of them. In the streaming steady state
the cursor sits between rows (`_curCol == 0`) on a blank row of its own;
after the shrink it pointed at a row that already held "streamed line N",
so the next append wrote "streamed line N+1" onto it. The merged row is
buffer content, so it persisted — nothing later repairs it.

Fix: bound the kept content rows by the row the cursor will occupy after
the clamps — `cursorRow` when the cursor is between rows, `cursorRow + 1`
when it is mid-row and legitimately shares the row it is writing. The
reconcile now always leaves the cursor on (or below) the last kept
content row.

Verified:

- regression test `shrink mid-stream with a full buffer never merges two
  rows (tin-m2vq)` in packages/tina_console/test/
  scrolling_text_region_test.dart (fails on the pre-fix code with
  "streamed line 30streamed line 31");
- tina_console 678/678 and the root suite 540/540 green;
- live repro clean from a fresh restart: `tool/merge_repro.sh 30 12 0`
  → 0 merged rows (was 1, persisting after settle), and
  `tool/crash_resize.sh 2` → 0 merged rows in both storm panes, both
  runs alive.
