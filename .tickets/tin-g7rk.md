---
id: tin-g7rk
status: closed
deps: []
links: []
created: 2026-08-15T00:00:00Z
closed: 2026-08-22
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

## Resolution (2026-08-22, branch asb/markdown-render)

Implemented per the design findings above; four commits on the PR.

**Renderer (pure)** — `lib/tui/markdown_renderer.dart`, markdown 7.3.1
(app-level dep only; import boundaries unchanged):

- `MarkdownStreamSplitter.push/flush` — the streaming contract: a block
  closes at a blank line outside a fence or right after a closing fence
  line; only newline-terminated lines considered; fence-aware (``` and
  ~~~, mismatched closers are interior content).
- `renderMarkdown(source, style)` → `MarkdownLine`s (runs of text +
  inline SGR code, optional row-level bar for fenced code). Blocks:
  p, h1–h6 (header style), blockquote (dim `│ ` rail), ul/ol (• / `N. `,
  nesting, tight/loose), pre (bar rows, verbatim), hr (dim `───`);
  unknown constructs fall back to text content — nothing is dropped.
  Inlines: strong/em (bit-composed `1`/`3`/`1;3`), code (inlineCode
  pill), a (link style + dim ` (href)` tail), img (alt + src), br.
  Entities/escapes decoded in prose; code spans/blocks keep their
  source bytes (the parser entity-encodes them once for HTML output —
  exactly one decode restores the source).
- `serializeLine(line, style, styled:)` — SGR-embedded when the surface
  renders color (`\x1b[…m…\x1b[0m\x1b[<base>m` so spans never leak past
  their run), plain-structural otherwise.
- Styles resolve from new ChatTheme fields (header/inlineCode/codeBlock/
  link; default/light/dark), pinned inside the `applySgrCode`
  vocabulary by theme tests (SGR 7 is silently dropped by styled_text —
  the codeBlock bar uses `100` instead).

**Sink integration** — `lib/chat_agent_sink.dart`:

- `text()` accumulates the raw turn verbatim and, on color surfaces,
  feeds the splitter; each closed block renders as beginStyle(bar |
  base) + serialized line + `\n` + endStyle (one style span per line —
  wraps and bars are carried by the region, never re-flowed). A blank
  separator is written between consecutive blocks.
- `newline()`/`toolStart()`/`notice()` flush the held tail first, so
  held prose can never render after the tool line or notice that
  follows it. `activityStart/Stop` do not flush (prose continues).
- Passthrough (headless `--prompt`, piped output) keeps the byte-exact
  legacy path — pinned by tests. No-color surfaces render structure
  without SGR.
- `onRawText` fires with the whole turn raw whenever a segment closes;
  `beginAssistantTurn()` abandons it (canceled turns don't leak).

**Raw view** — Ctrl+R (0x12, `ControlCode.ctrlR`, both input backends;
unclaimed app-wide — readline's reverse-search doesn't exist here):

- `LineEditor.onRawView` hook at the `onMaximizeToggle` dispatch rank
  (after modals, before the focus ring; alive in queue mode and the
  armed-readKey seam).
- The host keeps `lastRawMarkdown` (both halves reset on the user's
  message, so replay/history can't stack turns into it); the
  coordinator opens the generic full-screen viewer
  (`runToolOutputViewer`) with it. Default off — nothing renders
  differently unless the user asks.

**Tests** — renderer (38, structural matchers over runs), sink (11:
hold-back, mid-stream close, bar style, no-color, flush ordering, raw
ring, turn abandonment), tina_console keybind (4, byte-driven),
host ring (3). `panel_busy_cue`'s gate provider now streams a closed
block (`working\n\n`) — under block-granularity rendering that is the
mid-turn streaming observable the test pins.

**Verification**: `dart analyze` root — only the pre-existing tool/
errors (render_to_image/visual_test, untouched since the initial
release); tina_console — 3 pre-existing warnings. Suites: root 719 ✓,
tina_console 789 ✓, tina_index 55 ✓, fuzzy_ranker 11 ✓, attractor 82 ✓,
tina_engine 728 ✓ + the one known pre-existing sandbox failure
(process_tree_test 'kills a backgrounded descendant').

Out of scope per the ticket: tables, blockquote-in-list nesting beyond
one rail level; the raw view shows only the current/most-recent turn
(not a ring of past turns — the onCapped/`/output` pattern was chosen
for one live buffer, not ten).
