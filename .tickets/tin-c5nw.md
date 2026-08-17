---
id: tin-c5nw
status: closed
deps: []
links: []
created: 2026-08-15T00:00:00Z
closed: 2026-08-17T01:20:00Z
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

## Cause and fix (2026-08-17)

### Cause

`LineEditor._onEventInner` hands **every** event straight to an armed
`readKey` completer, before `_dispatchEvent` ever runs — and the focus ring
(the global-shortcut layer) lives inside `_dispatchEvent`. So while an
approval's `readKey` was pending, Ctrl+G never reached the `FocusManager`:
the panels did not cycle, and the key completed the approval's readKey as a
`ControlKey`, which askPermission maps to `''` → **denyOnce**. The
"leak" was not a routing race but a complete bypass of the global layer.

### Fix

`readKey({bool globalKeys = false})` (packages/tina_console/lib/src/
line_editor.dart). While a global readKey is armed, the editor offers each
event to the focus ring first (`_handleFocusRingKeys`, the same call
`_dispatchEvent` makes in its steps 2–3):

- Ctrl+G / Ctrl+W engage cycling; Esc returns focus home; while cycling the
  ring stays modal over every key (arrows/Tab/Enter included) — none of them
  answer the prompt.
- Any key the ring does not claim (y/n/a/d, anything else) is delivered to
  the prompt exactly as before.

Opt-in rather than default: the full-screen overlays (setup, spawn, prompts,
workflow editor/viewer) also sit on `readKey` and must keep owning their
keys — the prompts overlay documents Ctrl+G as "unused in the editor", so
making this the default would pop the focus ring behind an overlay.

Callers switched to `globalKeys: true` (every prompt that is NOT a
full-screen surface): `TuiConversationHost.askPermission`,
`WorkflowPermissionAsker._ask`, `TinaInterviewer._yesNo`.

### Verification

- `packages/tina_console/test/global_keys_readkey_test.dart` (4 tests):
  Ctrl+G cycles instead of answering (and Tab/Enter complete the cycle
  without answering), Ctrl+W behaves the same and 'n' answers once cycling
  is off, Esc returns focus home instead of denying, and a plain `readKey()`
  still delivers Ctrl+G (overlay shape unchanged).
- `tool/verify_global_keys.sh` — live probe at 120x40 and 80x24, stub
  scenario `crash_stream2`: (1) the panel frame switches focus(cyan) →
  cycling(yellow) on C-g, (2) no deny notice and no tool start follow, (3)
  a later 'y' resolves the approval and the tool streams. PASS post-fix.
  Pre-fix (fix stashed, same script): all three checks FAIL — frame stays
  cyan, "bash denied" follows C-g, the later 'y' lands in the editor.
- Root suite 540 green, tina_console suite 710 green; `dart analyze` at the
  pre-existing 29 issues (none new).
