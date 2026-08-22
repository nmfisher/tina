---
id: tin-g7rk
status: open
deps: []
links: []
created: 2026-08-15T00:00:00Z
type: feature
priority: 2
assignee: Nick Fisher
tags: [tui, markdown, rendering, feature]
---
# Render markdown returned by an agent in the TUI

## Context

Agents return markdown (headers, bold/italic, lists, inline code, code blocks, links). tina currently has **no markdown rendering** — no markdown package in any pubspec, no renderer in lib/ — so the TUI shows the raw source: `# Header`, `**bold**`, ```code``` fences appear as literal characters. Long agent answers are hard to scan.

## Scope

Render agent-returned markdown in the TUI output:

- Headers (levels + visual weight)
- Emphasis (bold / italic)
- Inline code + fenced code blocks (monospace / distinct background)
- Bullet + numbered lists
- Links (show URL or handle)
- Keep the raw text available (a copy/plain mode), do not lose content

Notes for the implementer:

- The UI is notcurses-based (dart_notcurses). Map markdown styles to notcurses attributes; no full rich-text engine needed.
- The `markdown` Dart package is the standard parser — check it fits the constraint set; else a small hand-rolled renderer for the common block/inline forms is acceptable.
- Headless mode: plain text is fine; optionally light ANSI styling — do not block the TUI work on it.
- Blockquote, tables: out of scope for v1 unless cheap.

## Acceptance criteria

- Agent responses in the TUI render markdown styles (headers, emphasis, code, lists, links).
- A plain/raw view of the response still exists.
- Renderer unit tests cover the block and inline forms listed.
- dart analyze clean; existing tests keep passing.

## Design findings (2026-08-22 investigation, branch asb/markdown-render)

Trace: provider stream → `ProviderStreamConsumer` → `ChatAgentSink.text`
(delta per chunk) → `ScrollingTextRegion.appendStyled`. Constraints found
in code:

- `ScrollingTextRegion` is append-only, wraps at write time in terminal
  cells, and never re-flows (`_writeInternal` / `_reconcileRows`,
  tina_console region.dart). There is no public API to rewrite
  already-written rows; once a row scrolls into history it is frozen.
  → markdown must be finalized before it is written.
- The style model is already rich enough: one row-level SGR code
  (`styleCode` → full-width background bars, used for code blocks) PLUS
  inline CSI runs inside row text, parsed/cached/diffed by styled_text.dart
  (bold/italic/underline + truecolor fg/bg). No emit-machinery changes
  needed for inline emphasis.
- Clean streaming boundaries exist: `sink.newline()` fires only at prose
  end (ToolCallStart / turn end — stream_consumer.dart:50-51,61-62,
  agent.dart:535); `toolStart`/`notice` route through `write()`, closing
  any open style. These are the flush signals for a held-back tail.
- Degradation is owned by the surface (`appendStyled` falls back to plain
  on passthrough/no-color); the sink must serialize plain-structural
  output in those modes, not SGR.
- Secondary consumers (panel-maximize `snapshotLines`, session-restore
  replay via history_replay → same sink) inherit whatever lands in rows,
  so both render consistently for free.
- `markdown` 7.3.1 verified installable (pub.dev reachable; deps only
  args+meta, both already in the tree). Hand-rolled renderer allowed by
  the ticket but re-implements nested-emphasis edge cases agents emit
  constantly — not worth it.

Decisions (user + session, 2026-08-22):

1. **markdown package + paragraph-granularity hold-back.** The sink
   buffers deltas; a block is rendered once closed (blank line outside a
   fence, or closing fence); the tail flushes on `newline()`/`toolStart`/
   `notice`. Long lists/fences held until close are accepted for v1.
2. **Renderer is a pure function** markdown string → styled lines
   (runs of text+SGR, optional per-line bar style), so unit tests need
   no terminal. App-level code; only theme fields land in tina_console
   (no markdown dep below the app — import boundaries stay clean).
3. **Raw view: default off, keybind to show.** Sink keeps the last
   assistant message's raw markdown (ring on the host, mirroring the
   onCapped/`/output` precedent); a keybind opens a viewer overlay.
   Headless stays plain per the ticket.

