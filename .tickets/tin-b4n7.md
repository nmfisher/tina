---
id: tin-b4n7
status: closed
deps: []
links: [tin-p8k2, tin-w8dl]
created: 2026-08-17T23:55:00Z
closed: 2026-08-18T01:05:00Z
type: bug
priority: 2
assignee: Nick Fisher
tags: [tui, chat-panel, coalescing, scroll]
---
# '\n'-terminated write into a full buffer leaves the new row unrendered (stale pending-row index after scroll)

## Context

Found while building the tin-p8k2 deterministic repro (found-A-while-fixing-B;
filed now, p8k2 continues — the repro can route around it). The coalescing
write path records the row index that received text BEFORE `_advanceRow`
scrolls the buffer, and never adjusts it for the shift.

## Repro (deterministic, real stack)

`tool/p8k2_repro.dart` at any geometry (120×40 verified): fill the chat with
more wrapped rows than fit (buffer full), ending the write with `\n`; then
append one more short line ending in `\n`. Observed (instrumented
`flushPendingWrites`/`_emitRow`, /tmp/p8k2_region.log):

```
flush: scrollCount=1 s=true windowWasFull=false (0/37) content=36 full=false rows=[36]
emit(36) SKIP visualRow=37 usable=37
```

The appended line's text lives at `_rows[35]` after the scroll (the trailing
`\n` ran `_advanceRow` → `removeAt(0)` + add, shifting every row down one),
but the pending set holds the pre-scroll index {36} — the fresh blank.
`_emitRow(36)` skips (visualRow 37 == usable), and nothing ever emits row 35.
No raster for the write at all (OpCounters: chatRowsEmitted +1, renderCalls
+0, gridWrites +0).

## Mechanism

- `_writeInternal` adds the pre-scroll row index to `touched`
  (region.dart:419-421); `_advanceRow`'s scroll branch bumps
  `_pendingScrollCount` in the coalescing path but — unlike the
  non-coalescing branch (region.dart:763-767, "add all rows") — adjusts
  nothing already recorded.
- `_contentRowCount` stays 36 (a row left and a blank entered), so
  `redrawAll` is false and `_pendingPaintRows` is the only record.
- The native-scroll fast path that would re-emit everything
  (`canScrollNative`) requires `windowWasFull && _contentRowCount ==
  _usableHeight`; with a trailing blank (content 36 < usable 37) it declines,
  and the fall-through loops over the stale index only.

Any second '\n'-terminated message into a previously-full buffer hits this;
the row stays invisible until an unrelated full repaint (resize, style flip,
buffer growth past a full-paint trigger). The live TUI mostly masked it
because agent turns stream '\n'-free chunks (no scroll mid-write) and
input/animation frames absorb pending chat.

## Fix (implemented 2026-08-18)

Invalidation, not index-shifting: `flushPendingWrites`'s fall-through now
full-repaints whenever `scrollCount > 0` and the native fast path did not
run. Shifting the pending indices alone would be insufficient — the MODEL
scrolled but the PLANE didn't, so every visible row is stale by
scrollCount, and only `_redrawAll` re-establishes the mapping. (The fast
path itself is untouched: it re-emits all rows anyway.) Windows that
scroll off the fast path are rare (they require a trailing blank at
window start), so the extra full repaint costs nothing in the common
streaming shapes.

## Acceptance

- Regression test: chat_native_scroll_test.dart 'scrolled window off the
  fast path (tin-b4n7)' — fill full, writeln (leaves the trailing blank
  that makes the next window not-full), then a '\n'-terminated write;
  asserts the new row paints and lands on the bottom plane row. Fails on
  the pre-fix code (verified by stashing the fix), passes after.
- Suites: root 543/543, tina_console 740/740 (739 + this test).
- Original repro passes: tool/p8k2_check.sh with the repro restored to
  the trailing-newline shape — the reply row now renders AND the border
  oracle stays 38/38 (the b4n7 path routes the reply through putAt with
  no snapshot, which the tin-p8k2 erase-split handles). Live
  q4vz_live.sh ascii run: 0 borderless.
