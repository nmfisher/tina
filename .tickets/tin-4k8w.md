---
id: tin-4k8w
status: open
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
