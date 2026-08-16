---
id: tin-4k8w
status: closed
deps: []
links: [tin-3x9v, tin-6a2f]
created: 2026-08-15T17:35:00Z
type: bug
priority: 1
assignee: Nick Fisher
tags: [tui, rendering, corruption, tool-output, streaming]
---
# Chat region renders garbage: rows truncated at ~35 cols with the bottom border drawn mid-panel

## Context

During a sweep run (T9, 120×40, 2026-08-15), the chat region's rows became
permanently garbled while tool output was streaming:

```
│  bash: git ls-files examplesyanm│
│  failed: cwd escapes the proyanm│
│  bash: ls -la /workspace/exayanm└yanm──────────────────────────it -C /workspace/examples/wor│
```

Every chat row's text truncates around column ~35 (mid-token), followed by
stray "yanm" text, the panel's bottom border (`└───`) drawn MID-ROW, and the
next line's text spliced in. The corruption persists across subsequent
renders (captured several times). The approval prompt for the next tool call
still renders below at the full width, so only the streaming tool-output rows
are affected. The TUI did NOT crash in this instance (the crash ticket
tin-3x9v hits the same streaming-render area).

## Repro

1. tina TUI in detached tmux (reply injection), warm environment record.
2. Ask a task whose agent runs several bash commands back-to-back (T9-style
   refactor); answer the approvals.
3. Observed: while the tool output streams, the chat rows on screen get
   truncated to ~35 columns with the bottom border + next command text
   spliced into the right portion. Not every run — timing-dependent.

Second repro (deterministic): resize the window WHILE a turn is streaming
(`tmux resize-window -x 60 -y 18` then `-x 150 -y 48` mid-turn). The panel
re-renders but the chat content is wiped: only a fragment of the last
message remains on the first row, the bottom border is drawn mid-panel, and
the rest of the rows are blank. A subsequent keypress does not repaint.
The agent keeps running (process alive); only the display is lost.

## Notes

The corrupted rows look like a render where the chat region drew rows at a
narrower width (or with a stale column offset) and the row buffer's tail
(previous frame's border/text) was never cleared. Same area as tin-3x9v
(SIGSEGV during streaming renders) and tin-6a2f (approval line overlap) —
likely a shared concurrent-render row-state bug.

## Acceptance

- Streaming tool output always renders at the full panel width; no garbage
  tails or mid-row borders; repeated streaming runs stay clean.
- Regression: a virtual-terminal test streaming tool output + interleaved
  chat rows asserting full-width rows (no truncation artifacts).

## Resolution (2026-08-16)

Two distinct bugs, two fixes, one ticket:

1. **Mid-stream shrink wiped the chat** (`_reconcileRows`): on a height
   shrink the row buffer evicted the first `(rows.length - h)` rows. With a
   partially-filled buffer (content top-aligned, blanks at the bottom — the
   normal mid-turn state) that evicted every content row into scrollback and
   kept the blank tail. Fix (92deaef): keep the most recent content rows in
   the window, retain evicted content in history, drop only the blanks.
   Regression: `scrolling_text_region_test.dart` "shrink mid-stream keeps
   the most recent content".

2. **Terminal/notcurses damage desync after resize** (the `└───` mid-row
   splice + stale fragments): tmux keeps the BOTTOM of the alternate screen
   when a pane shrinks (verified empirically), so the terminal's grid
   diverges from notcurses' retained frame; per-cell damage tracking then
   skips cells notcurses considers unchanged and the dropped top rows stay
   on screen forever. Fix (22bf97f): `notcurses_refresh` (full re-emission)
   at the end of the canonical resize sequence
   (`ResizeCoordinator.handleResize`). Regression: resize_coordinator_test
   pins the refresh as the final resize step; resize_refresh_test pins the
   forwarding chain + cursor re-park.

Live verification: stub-provider turn, resize 120x40 -> 60x18 -> 150x48
mid-stream from a clean restart — the streamed tail renders full-width and
the frame stays intact. Suites: root +538, tina_console +674.
