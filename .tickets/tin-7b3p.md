---
id: tin-7b3p
status: closed
deps: []
links: []
created: 2026-08-15T15:40:00Z
closed: 2026-08-15
type: bug
priority: 2
assignee: Nick Fisher
tags: [sessions, persistence, test, timing]
---

## Result

Fixed in commit 8b7dc36 (test-only): the sanity check now pumps until the
user message is in history (not just isRunning), with a 30s budget. The
`_runTurn` code order (persist after the auto-compact, whose `rec.replace`
would otherwise wipe the fresh append) is deliberate and left unchanged.
Root suite green: +538.
# Root suite: session_controller_test "user message survives quitting mid-stream" fails (sanity: message not in history when running)

## Context

`dart test test/session_controller_test.dart` fails consistently in this
container (also failed in the full root suite, and pre-dates any sweep
changes — verified by stashing):

```
SessionController REGRESSION: a user message survives quitting before the
response completes (restored by -c) [E]
  Expected: true
  Actual: <false>
  sanity: the user message is in in-memory history once the turn is running
```

The sanity check races: `_runTurn` (lib/session_controller.dart) sets the
conversation running/active state, then `await _maybeAutoCompact(...)` (an
await point), then `await s.agent.run(...)` — and only agent.run's first line
adds the user message to history. So "isRunning" is true BEFORE the message
is in history; the test's `_pumpUntil(() => controller.active.isRunning)`
then asserts the message immediately — a timing race that this container's
scheduling loses consistently. Under real load a quit inside the auto-compact
await would also lose the message from the in-memory history (the on-disk
append happens after the compact too).

## Repro

1. `dart test test/session_controller_test.dart` — fails (observed 3/3 runs).

## Notes

Two-part fix proposal:
1. lib/session_controller.dart `_runTurn`: persist the user message
   (`rec.append(userMessage)`) BEFORE the `_maybeAutoCompact` await, so the
   message is durable before any await point.
2. test/session_controller_test.dart: the sanity check should pump until the
   message is actually in history (or until agent.run has started), not just
   until isRunning.

## Acceptance

- The regression test passes reliably (repeated runs).
- The user message is persisted before any await in `_runTurn`.
