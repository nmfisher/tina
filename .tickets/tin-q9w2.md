---
id: tin-q9w2
status: closed
deps: []
links: [tin-k4m8]
created: 2026-09-20T05:05:28Z
closed: 2026-09-20T06:05:00Z
type: bug
priority: 1
assignee: Nick Fisher
tags: [tui, permissions, strip, layout, panel]
---
# Mode strip label is not visible: the primary panel's input row collides with the strip row

## Context

The dedicated mode/status strip (commit 6ce9bbe) is invisible in the tiled
(first-boot) layout: the operator never sees `mode: ask` from the first
frame, so Shift+Tab cycling looks like it does nothing (until the scrollback
announce from tin-k4m8, which this ticket's sibling).

## Root cause (established from source, to be pinned by failing test first)

`ScreenLayout.fromSize` (packages/tina_console/lib/src/screen_layout.dart):
in a full-width layout (`sidebarWidth == 0`) it reserves
`bottomBorderRow = h-1` and `stripRow = h-2`, `inputRow = h-3`. But the
primary conversation is a self-drawing `PanelFrame` whose outer box spans
`topBorderRow..bottomBorderRow` (lib/tui/panel_manager.dart `layout()`), and
`PanelFrame.inputRect` is the bottom INTERIOR row of that box —
`b.bottom - 1 = (h-1) - 1 = h-2` — which IS `stripRow`.

First paint runs `ResizeCoordinator.handleResize` →
`panelManager.relocateInput(primaryFrame, force: true)` →
`screen.input.setBoundsOverride(target.inputRect)` and the editor renders
`> ` straight onto the strip row (region.dart `InputRegion.render` →
`putAtAbsolute`). The panel chrome also paints its input row there. The
strip painter (`Screen._renderStrip`, screen.dart:538) runs only when
something calls `setModeLabel`/`setErrorStrip`/`redrawFrame`, so from then
on the label is gone: the row belongs to the input.

The startup `screen.setModeLabel(...)` call in `TuiCoordinator.create`
(lib/tui_coordinator.dart:1041) runs before `run()`'s first paint
(`screen.enterAltScreen()` happens in `run()`), and `_renderStrip` writes
unconditionally through the backend; the write lands pre-alt-screen but is
re-asserted by `redrawFrame()` inside `enterAltScreen` — which then gets
clobbered by the panel input row painted at the same row. Result: no visible
mode label, ever, on a fresh tiled boot.

Sidebar layouts keep `stripRow = h-1` clear of the input row (the sidebar's
bottom box border takes `h-2`), which is why the strip was believed to work.

## Repro

1. `tina` (tiled, no sidebar), 80x24 terminal, wait for first paint.
2. Expected: `mode: ask` visible beneath the input row (row 22), always.
3. Actual: row 22 shows the input prompt `> ` and the panel's input row —
   no mode label. Submitting/`clearErrorStrip`/resize never brings it back
   (nothing repaints the row; the input owns it).

## Acceptance

- A failing (then passing) test asserts the RENDERED strip row shows the
  mode label across: first paint, submit, panel relocation, resize,
  side-panel toggle, setErrorStrip/clearErrorStrip.
- The mode label never enters the conversation scrollback.
- Sidebar layouts keep working (strip stays below the sidebar boxes).
- `/permissions` message line and the approval-pending Shift+Tab cycling are
  unaffected.

## Resolution

Root cause PROVEN by probe (packages/tina_console, probe files deleted after
evidence): in full-width layouts `ScreenLayout` gave `stripRow = h-2` while
the panel box spanned `topBorderRow..bottomBorderRow (h-1)`;
`PanelFrame.inputRect = h-2` = strip row, so first paint's `relocateInput` →
`InputRegion.render` erase wiped the label. Pre-alt-screen startup write
never presented. Sidebar layouts were collision-free by accident.

Fix, three commits:

- tina_console a9905a9 — uniform layout rule in every layout:
  `bottomBorder = h-2`, `stripRow = h-1`, `inputRow = h-3`; boxes stop above
  the strip.
- tina_console 3391a63 — `Screen.putAtAbsolute` re-asserts `_renderStrip()`
  when a write touches the strip row (recursion-guarded); strip no longer
  repairs border corners (no box owns its row any more).
- tina 57ac02e — startup `setModeLabel` moved from `create()` (pre-alt-screen,
  never visible) into `run()` after `_refreshSessionMenu`, so the label joins
  the first presented frame; `panel_manager` parked-panel virtual slots moved
  strictly below the visible stack (the old `slot*perPanel` slot folded onto
  the last visible panel once the box shrank a row).

Tests: coordinator-level regression via `VirtualTerminal` grid decode —
label on the strip row from the first frame, on exactly one grid row, never
in scrollback; label survives `/clear`, setErrorStrip (mid-stream
`StreamNotice`) and clearErrorStrip (turn boundary). Root suite 911 passed;
tina_console 916 passed.

Not covered by automated test: resize and side-panel toggle survival
(exercised indirectly by the subpackage strip/putAtAbsolute tests and the
panel_manager suite); noted as residual manual-verification surface.
