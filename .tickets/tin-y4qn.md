---
id: tin-y4qn
status: open
deps: []
links: []
created: 2026-08-15T00:00:00Z
type: bug
priority: 2
assignee: Nick Fisher
tags: [tui, panels, async, animation]
---
# Panels: async progress + loading animation semantics when unfocused

## Context

Two related observations about TUI panels (conversation/run panels):

1. **Async progress while unfocused.** Cycling away from a panel while a task or response is pending appears buggy (or at least unverified): does the pending work proceed asynchronously when the panel is not focused? Messages, agent turns, and tasks must keep progressing regardless of which panel has focus.

2. **Loading border animation semantics.** The "loading" border animation currently seems to run in cases where the panel is not actually doing anything. It should animate ONLY when that panel/agent is genuinely busy: an agent turn in progress, a tool call running, or awaiting user input mid-turn. When the panel is idle — just waiting for the user to send a new message — it must NOT animate.

## Scope

- Verify (and fix if broken) that all messages/tasks/agent turns proceed asynchronously when their panel is unfocused.
- Define the animation trigger precisely from real activity state (agent thinking / tool running / awaiting user input) and make the border reflect it; idle panels show a static border.

## Acceptance criteria

- A panel's pending work completes while the panel is not focused (no stall, no dropped events).
- Border animation appears exactly when the panel's agent/tool/user-input is active; an idle panel waiting for a message shows no animation.
- Document the activity-state mapping used; dart analyze clean; existing tests keep passing.
