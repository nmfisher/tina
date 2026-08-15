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
