---
id: tin-uzo3
status: open
deps: []
links: []
created: 2026-08-08T04:22:36Z
type: bug
priority: 2
assignee: Nick Fisher
tags: [tui, transparency, tool-calls, ux]
---
# Tool calls in agent panels hide their arguments (glob shows no pattern)

In the TUI, a tool call renders as a dim line like '→ glob' with no arguments. The rendering path: every agent (main and sub-agents, same BusSink(ChatAgentSink) wiring) renders ToolStartEvent via _describe in lib/chat_agent_sink.dart, which formats only bash (command), read/write/edit (path); every other tool falls to the default and shows only its name. glob, grep, search, collect, delegate and all other tools hide their input. Output chunks still render, so the user sees results without the query. Fix: add cases for the read-only search tools (glob pattern, grep pattern and path, search query) and a compact generic fallback that shows a truncated one-line summary of the input (about 80 chars) instead of only the name, so no tool hides its arguments. Add unit tests for the formatting. Follow repo conventions: failing test first, confirm it fails, then implement.

## Acceptance Criteria

Every tool call in the main and sub-agent panels shows a compact description of its input; glob shows the pattern; grep and search show pattern or query; unknown tools show a truncated input summary; tests pass.

