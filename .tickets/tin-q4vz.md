---
id: tin-q4vz
status: closed
deps: []
links: [tin-m2vq, tin-4k8w, tin-p8k2]
created: 2026-08-17T07:55:00Z
closed: 2026-08-17T11:30:00Z
type: bug
priority: 2
assignee: Nick Fisher
tags: [tui, chat-panel, rendering, paste]
---
# Chat panel renders expanded paste rows without the left border (and one wide-char row drops a char)

## Context

Found driving the "paste 5k chars" seed. After a large pasted message is
submitted, the chat panel expands its content; a subset of those rows
renders with a **space where the left `│` border belongs**, while other
rows of the same message keep it. The corruption survives a repaint
(resize nudge re-measured: 28 borderless before and after), so it is in
the row layout itself, not the diff-repair path.

With CJK/emoji in the body, one row per section additionally renders
**corrupted text**: `long-token:` → ` long-toke : ` — the `n` is gone and
a space appears before the `:`. With an ASCII-only body the same rows are
borderless but the text is intact, so the two defects are independent:

- border loss: wrap/diff-path, no wide chars needed;
- dropped char: wide-char/ZWJ width accounting (the row above contains
  `漢字…🏳️‍🌈👨‍👩‍👧‍👦`; a pad-space for VS16/ZWJ miscounts and eats the
  following glyph cell).

Persistence is NOT affected: the submitted message round-trips
byte-identical through the session JSONL (verified by diff, 5999/6000
with only the conventional trailing-newline trim).

## Repro

1. `python3` a ~6 KB body of sections:
   `-- section N --` / `the quick brown fox…` /
   `CJK: 漢字テスト混合 N · emoji: 🏳️‍🌈 👨‍👩‍👧‍👦 ✓` /
   `long-token: ` + 180×`x` + N / `\tindented line with tab\tends`.
2. Fresh HOME (stub provider), launch tina in `examples/workspace` at
   120×40, wait for paint (~11 s under `dart run`).
3. `tmux load-buffer body && tmux paste-buffer`; editor shows
   `[Pasted text : 6000 chars]`; Enter.
4. Capture the pane: count rows whose first char is not `┌│└`.

Observed 3/3 runs with content on screen: 11 borderless rows (ASCII body
and CJK body alike); the CJK body additionally shows ` long-toke :` on
the first row of each wrapped `long-token:` line. In a busier session
(queued messages after the paste) 28 rows were borderless.

Borderless-row selection varies with content (first row of wrapped
lines, `-- section N --` lines, plain lines) — consistent with a
row-diff/rewrite segment that includes column 0 when a row's length
class changes, writing a space over the border cell. Start in the chat
row diff / row storage code (`chat_row_diff_test.dart`,
`chat_row_storage_test.dart` exist as harnesses).

## Session findings (2026-08-17, hunt 1)

- **ANSI/VT path is clean.** The corpus shape reproduced at the
  VirtualTerminal level (`test/chat_paste_border_test.dart`: framed chat
  region, 12 scrolling sections, wide-char variant) keeps every `│` and
  every glyph — so the row-content/wrap layer (`_writeInternal`,
  `_emitRow` diff) is exonerated on the ANSI surface. The bug lives in
  the notcurses path: the chat region's opaque child plane geometry, the
  native-scroll fast path, or the busy-toggle border repaint.
- Comet ruled out: it sweeps the top/bottom rails only
  (conversation_panel.dart:200-210), never the left rail.
- Correlation with busy time: 28 borderless rows in the 4-turn session,
  11 in the 2-turn one — consistent with a busy-toggle/native-scroll
  path that skips rows, not with static layout math.
- Next hunt: `tool/render_to_image.dart`-style notcurses-context test
  (or the notcurses_backend_test harness) driving the same corpus with
  the busy toggle flipping mid-stream; check `_ensureSurface`
  resize/move on geometry change and the `_pendingScrollCount`
  coalesced native scroll for a column-0 clobber.

## Hunt 2 (2026-08-17): ROOT CAUSE FOUND — width-table disagreement,
terminal-side autowrap, damage-blind spot

Reproduced deterministically with the live app (tool/q4vz_live.sh, stub
emoji_cjk scenario, 120x40, paste5k.txt): **11/11 borderless rows, every
one a wide-char row or the row directly below one**. ASCII-only body
(paste_ascii.txt, same shape): **0 borderless**. The earlier "ASCII body
reproduces" note was contamination from wide rows in the surrounding
session (the stub turn / ceremony).

Mechanism, from the raw byte stream (tmux pipe-pane):

1. Every column budget in the chat emit path counts **1 column per
   rune** — `_writeInternal`'s wrap (`_curCol += run.length`),
   `_emitRow`'s background pad (`_visibleLen`), `clipToVisibleColumns`,
   `_emitSgrStyled`'s run advance, `diffStyledRuns`' colOffset.
2. A wide/ZWJ row therefore emits content + pad whose width is honest
   per OUR table but wider per the real terminal's table: notcurses
   composes `🏳️‍🌈` as 2 cells and `👨‍👩‍👧‍👦` as 2, tmux lays them out as
   ~4 and ~8 columns. The rasterized run (content + pad spaces, cursor
   addressing only at run start) drifts right in tmux's grid and
   **autowraps past the pane's right edge onto the next screen row,
   columns 0..k** — blanking the left `│` border and the first cells of
   the next row (`long-token:` → ` long-toke :`, x's blanked).
3. notcurses' retained grid still holds the correct cells, so its
   damage tracking considers those cells unchanged and **never
   re-emits them** — the corruption survives repaints and resizes
   (matching the observed persistence).
4. The two defects share this root: the dropped `n`/shifted `:` are the
   wrapped-over cells of the row following a wide row; the borderless
   col-0 is the same wrap eating the border column.

Exonerated along the way: `_ensureSurface` resize/move
(ncplane_resize(0,0,0,0,0,0,h,w) preserves the absolute origin — probe:
tool/resize_probe.dart), native `_pendingScrollCount` scroll, the
comet, and plane geometry (live layout was coherent: full-width chat,
plane 118 wide).

Fix direction: one conservative terminal-width function (wide ranges =
2, combining/VS16 = 0, else 1; VS16 = 1 so pictographic+VS16 errs
high), applied at every column-budget site in the emit path — wrap,
pad, clip, run advance, diff colOffset. Over-counting is safe (bar a
column short at the right edge); under-counting (today) wraps.

## Fix (2026-08-17, hunt 3): one width table, every budget site

`packages/tina_console/lib/src/term_width.dart` is now the single
terminal-cell table (doctrine: err high, never low — over-counting costs a
column at the right edge, under-counting wraps). Applied at every column
budget in the emit path:

- `_writeInternal` wrap — budget in cells; a wide rune with insufficient
  room wraps to the next row (terminal behavior) instead of overflowing;
  surrogate pairs never split.
- `_visibleLen` (bar pad) — cells; bars now pad one column SHORT of the
  region width so an exactly-full row can't invite the rasterizer's
  autowrap continuation (both pad sites: `_emitRow` + `_renderRowText`).
- `clipToVisibleColumns` — clips by cells, drops a boundary-crossing rune
  whole.
- `_emitSgrStyled` / `_emitSgrStyledWalker` run advance — cells.
- `diffStyledRuns` colOffset + `_emitRow`'s oldTailWidth — cells, agreeing
  with the emit advance.
- `visibleColumns`, `_appendToRow` — cells.

ZWJ = 1 cell (not 0): measured live, tmux lays each cluster member out —
so 👨‍👩‍👧‍👦 budgets 11. VS16 = 1 so pictographic+VS16 errs high. Astral = 2.
Cyrillic/Hebrew/Arabic combining marks = 0; unlisted marks count 1 (errs
high by design).

Tests (all failing on the unfixed lib, green on the fixed):
- `test/chat_paste_border_test.dart` — the VT harness now models tmux-class
  glyph widths (a harness sharing production's table shares its blind
  spots), plus a full-width-panel edge-reaching regression test.
- `test/term_width_test.dart` — the table itself.
- wide-char cases in `styled_runs_test.dart` (diff colOffset) and
  `notcurses_backend_platform_test.dart` (run advance).

Suites: tina_console 736/736, root 543/543. Live repro from clean
restarts: 0 borderless (was 11/11), no glyph drops — CJK body ×2, ASCII
body ×1.

Residual (filed as tin-p8k2): a 1-in-3, 1-cell blank row can still lose
its left border when the reply prose contains a ZWJ family cluster — the
notcurses RASTER's erase run relies on autowrap to cross a row boundary
and tmux's cluster layout is wider than nc's by 9 cells. Below our layer;
fix direction on that ticket.

## Acceptance

- A VirtualTerminal-level regression test: a chat panel rendering an
  expanded multi-section paste keeps `│` at column 0 of every content
  row, and a row following a wide-char/ZWJ row renders its text exactly.
  (Pinned green at `test/chat_paste_border_test.dart` — keep it as the
  corpus template; the failing layer is below it.)
- Live repro passes from a clean restart.
