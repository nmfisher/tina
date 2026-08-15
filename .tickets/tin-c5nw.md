---
id: tin-c5nw
status: open
deps: []
links: []
created: 2026-08-15T00:00:00Z
type: bug
priority: 1
assignee: Nick Fisher
tags: [tui, keys, approval, input-routing]
---
# Ctrl+G (panel cycle) leaks into an open approval request

## Context

In the TUI, when an approval/permission request is showing (e.g. the permission asker for a write/edit approval, or a gate), pressing **Ctrl+G** to cycle panels ALSO delivers the keystroke to the approval request — the approval consumes the key instead of (or in addition to) the panel cycle. Incorrect: a global shortcut must not become approval input.

## Repro

1. Trigger an approval request so the prompt is showing.
2. Press Ctrl+G (panel-cycle shortcut).
3. Observed: the approval request receives the key (character/action lands in the approval input) instead of the panels cycling — or both happen.

## Suspects

- Global key dispatch vs approval-local input order: the approval handler grabs keys from the shared editor/readKey before the global shortcut handler runs (or the shortcut is not filtered out of the approval's key stream).
- The shared modal queue (AttentionQueue — gates, loop-budget confirms, permission asks serialize through it) and how TuiConversationHost.askPermission / WorkflowPermissionAsker read keys.

## Acceptance criteria (for the fix run — not started)

- Ctrl+G (and other global shortcuts) cycle panels while an approval is open.
- The approval request does NOT receive the shortcut key; its own keys (y/n/a/d etc.) still work.
- No regression to approval key handling or panel cycling.
