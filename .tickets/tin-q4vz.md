---
id: tin-q4vz
status: open
deps: []
links: [tin-m2vq, tin-4k8w]
created: 2026-08-17T07:55:00Z
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

## Acceptance

- A VirtualTerminal-level regression test: a chat panel rendering an
  expanded multi-section paste keeps `│` at column 0 of every content
  row, and a row following a wide-char/ZWJ row renders its text exactly.
- Live repro passes from a clean restart.
