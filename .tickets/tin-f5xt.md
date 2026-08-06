---
id: tin-f5xt
status: open
deps: []
links: []
created: 2026-08-06T11:36:51Z
type: feature
priority: 2
assignee: Nick Fisher
tags: [daemon, sessions, attach, detach, tmux]
---
# Session daemon for tmux-like attach/detach of agent sessions

Tina currently persists sessions to disk, but agents stop when the TUI exits — it is persistence, not a live daemon. Add a tmux-like session daemon: a background process that owns agent sessions, keeps them running after the TUI detaches, and allows re-attaching from a terminal or inspecting from other clients (e.g. via Signal). Sessions should survive TUI exit and be listable/attachable/detachable at will.

## Acceptance Criteria

Agent sessions keep running after the TUI exits; tina --resume re-attaches to a live daemon-owned session with full scrollback; a detach command leaves agents running while /exit offers detach-or-kill; tina --list-sessions distinguishes live from persisted sessions; the existing per-session lock still blocks double-attach with --force as the escape hatch

