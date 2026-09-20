---
id: tin-k4m8
status: open
deps: []
links: [tin-q9w2]
created: 2026-09-20T05:05:28Z
type: bug
priority: 1
assignee: Nick Fisher
tags: [tui, permissions, shift-tab, scrollback, host]
---
# Shift+Tab mode cycling prints a "permission mode" line into the scrollback on every press

## Context

Operator report: cycling the permission mode with Shift+Tab drops a line into
the conversation scrollback on every press. The mode already has a dedicated
always-visible strip label (commit 6ce9bbe), so the announce is redundant
visual noise — and worse, it scrolls the transcript one row per press while
the operator is still deciding.

The `onBackTab` hook announces through
`sessionManager.activeConversation.host.showMessage('permission mode:
<label>\n')`, which routes through `TuiConversationHost.showMessage` →
`chat.write` — i.e. permanent scrollback, not a status surface.

## Repro

1. `tina` (any model), wait for first paint.
2. Press Shift+Tab four times.
3. Expected: mode flips ask → read-all → allow-edits → auto → ask, nothing in
   the transcript.
4. Actual: four `permission mode: …` lines appended to the scrollback; every
   press scrolls the transcript.

`/permissions <mode>` (lib/session_commands/command_families.dart:755) keeps
its message on purpose — it is a deliberate command invocation with visible
effect; that line is out of scope for this ticket.

## Acceptance

- Cycling with Shift+Tab writes no `permission mode:` line into the
  conversation scrollback (pinned by a coordinator test asserting the
  absence in `io.written`).
- The mode still cycles (base policy + every live conversation), and the
  strip label still updates live — including while an approval is pending
  (`TuiConversationHost`'s backtab-during-approval path).
