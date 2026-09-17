---
id: tin-w7dr
status: open
deps: []
links: [tin-6a2f, tin-c5nw]
created: 2026-09-17T00:00:00Z
type: bug
priority: 1
assignee: Nick Fisher
tags: [tui, approval, wheel, scroll, redraw, input-routing]
---
# Mouse wheel while an approval request is pending duplicate-prints the approval request

## Context

Operator report: when an approval/permission request is showing
(`approve? [y] allow once [a] allow always [d] deny ‹ `), scrolling the
mouse wheel makes the approval request print again — a duplicate copy of the
prompt (and, in at least one instance, the surrounding preview rows) lands
in the transcript. The approval surface is the safety-critical path: a
duplicated or visually scrambled prompt row is exactly where a misread
option ("did my deny land?") turns into a wrong answer. Not yet reproduced
locally — the fix run's first job is a live repro.

## Repro

1. Run in the TUI with `[tui] mouse_wheel = true` (wheel events are only
   delivered when mice are enabled — `packages/tina_console/lib/src/backend/notcurses_backend.dart:152-163,322-329`).
2. Trigger an approval request (e.g. a bash/edit call that needs the asker)
   so `approve? … ‹ ` is on screen and `readKey` is armed.
3. Scroll the mouse wheel (either direction).
4. Observed (operator report): the approval request prints a second time.
   Expected: the approval row stays exactly as it was; the wheel either
   scrolls the scrollback or is a no-op while the modal pends.

## Suspects

The approval draw path and the scroll/redraw machinery intersect in three
places; the duplication must live in one of them.

1. **The approval key loop consumes wheel events but the wheel still
   scrolls.** `TuiConversationHost.askPermission`'s loop
   (`lib/host/tui_conversation_host.dart:297-362`) handles `CharInput`,
   `ArrowKey`, `EscapeKey`, Ctrl+C/Ctrl+Enter/Backtab — a `ScrollEvent`
   matches none, so it falls to the "not an answer key" branch
   (`:356-361`) and is swallowed (first one prints the #51c ack; the
   author's comment at `:292-296` already anticipated wheel spam arriving
   here). But tin-c5nw's `globalKeys: true` fix only hands
   cycling keys (Ctrl+G/Ctrl+W/Esc) to the focus ring — it does not route
   `ScrollEvent` to the focused panel's `onWheel`, because `readKey`
   bypasses `_dispatchEvent` (that bypass was the whole tin-c5nw cause).
   Meanwhile the panel claims `ScrollEvent` in its own
   `handleEvent` (`packages/tina_console/lib/src/conversation_panel.dart:213-216`,
   routing to `onWheel` → `host.chat.scrollBy` via
   `lib/tui/conversation_panel_coordinator.dart:80`). If an event can
   reach BOTH the panel claim and the approval loop — or if the editor's
   early-claim path (`packages/tina_console/lib/src/line_editor.dart:647`,
   `:913-915`) delivers it twice — the transcript scrolls while the
   approval's cursor assumptions go stale.
2. **scrollBy/redraw vs the open partial row.** The approval row is a
   mid-row write held open with a `rowOwner` token
   (`tui_conversation_host.dart:250,264`; ownership mechanics
   `packages/tina_console/lib/src/region.dart:40-47`, the tin-6a2f fix).
   `scrollBy` while `_scrollOffset > 0` re-renders the visible window from
   the row buffer; on notcurses it can also issue a native
   `ncplane_scrollup` (`region.dart:62-73` coalescing window,
   `notcurses_backend.dart:748-759`, gated on `noteContentRows`). A
   redraw that re-emits the still-open partial row — or a native scroll
   that moves the plane while the region's buffered cursor still points at
   the old position — would print the approval a second time, and every
   later `chat.write(…, rowOwner: rowToken)` (the eventual y/a/d echo)
   would then land in the wrong place.
3. **Wheel translated to arrows by the terminal.** With mice NOT enabled,
   the backend comment documents the terminal translating wheel → arrow
   keys (`notcurses_backend.dart:152-156`). Arrows ARE approval keys
   (option selection, `tui_conversation_host.dart:316-326`), and each
   arrow press **clears and rewrites the approval row** via
   `'\x1b[1A\x1b[2K'` (`:324-326`). A wheel translating to a run of
   arrow-key events would redraw the row repeatedly — and if the clear is
   off by a row (e.g. the ack from #51c added a line the cursor math
   didn't account for), each rewrite leaves the previous copy behind:
   literally duplicate prints. Check whether the operator had
   `mouse_wheel` off — this suspect needs no double-delivery at all.

Prior art to reuse: tin-6a2f (row-ownership token and its test,
`packages/tina_console/test/approval_row_ownership_test.dart`), tin-c5nw
(readKey/global-keys routing + `tool/verify_global_keys.sh` live probe),
`tool/approval_key_probe.sh` (existing approval-path probe; notes the
answered-approval echo behavior).

## Acceptance

- Repro first: extend `tool/approval_key_probe.sh` (or add a
  `tool/verify_*.sh` in the tin-c5nw style) that opens an approval in a
  stub scenario and feeds wheel notches; capture the transcript with and
  without the fix. Pre-fix must show the duplicate; post-fix must not.
  Establish which suspect (1/2/3) is real before fixing.
- While an approval pends, a wheel notch (mice on) either scrolls the
  chat scrollback or does nothing — it never duplicates, clears, or
  rewrites the approval row. With mice off, terminal-translated wheel
  events must not behave as approval-option arrow presses.
- The `rowOwner` token invariant holds: writes from the approval loop land
  on the same physical row before and after any scroll that happens
  mid-prompt.
- Regression test alongside `approval_row_ownership_test.dart` (fake key
  source delivering `ScrollEvent` mid-`askPermission`).
- Root suite + tina_console suite green; live probe passes from a clean
  restart per `.tickets/README.md` working rules.
