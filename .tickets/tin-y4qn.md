---
id: tin-y4qn
status: closed
deps: []
links: [tin-4k8w]
created: 2026-08-15T00:00:00Z
closed: 2026-08-18
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

## Resolution (2026-08-18)

Root cause — the busy-cue signal chain carried a **focus gate**, not an
activity gate, plus one surface that never signaled at all:

1. `SessionController._runTurn` raised `host.setActivity(true)` only when the
   conversation was the active one at turn START (session_controller.dart),
   and cleared it only when active at turn END. Two failure modes:
   - Turn ends while unfocused (user cycled away mid-turn) → clear skipped →
     the idle panel's comet swept forever. This is observation 2.
   - Turn starts while unfocused (queued-message drain, workflow-result
     injection into a background conversation) → raise skipped → a genuinely
     busy panel showed a static border.
2. Delegated sub-agent panels never signaled at all: their turns run through
   `SubAgentScheduler._runAgent`'s own `agent.run`, not the controller's turn
   loop, so nothing ever called `host.setActivity` — a live sub-agent panel
   was permanently static.

Async progress (observation 1) was verified sound by inspection + pinned by
test: turns are fire-and-forget per conversation, output streams into the
conversation's own (detached-but-buffering or side-panel) region, and each
conversation drains its own message queue at turn end regardless of focus.

Fix (commit "fix(tui): panel busy cue tracks activity, not focus"):

- `session_controller.dart`: raise/clear `setActivity` unconditionally at
  turn start/end. Hosts without a bound panel no-op the cue (background
  conversations keep working, just invisible).
- `sub_agent_scheduler.dart`: `_run` raises `job.panelHost?.setActivity(true)`
  when the job starts running; `_finish` clears it on every terminal path
  (done/errored/cancelled).

### Activity-state mapping (canonical doc: `HostInterface.setActivity`)

A panel's border animates ⇔ the conversation displayed in that panel has a
turn in flight (`Conversation.isRunning`) — agent thinking, streaming, tool
execution, and awaiting an in-turn permission response all count (the turn
stays in flight across `askPermission`). Idle — waiting for the user's next
message — is static. Non-turn panel owners drive the same signal from their
own lifecycle: workflow runs via `run.isRunning`/`onFinished` (already
correct), sub-agent jobs via the scheduler (fixed here). `setIdle(true)` at
presentation time re-syncs an incoming idle conversation as a stale-cue
guard.

### Verification

- Regression tests (all failed pre-fix, pass post-fix):
  - `test/tui/panel_busy_cue_test.dart` — real Screen/PanelManager/
    ConversationPanelCoordinator/SessionController harness over FakeStdio:
    turn-ending-unfocused clears the cue; turn-starting-unfocused raises it;
    the comet renders on the unfocused busy panel and the rails repaint
    static after; unfocused conversation streams, completes, and drains its
    queue without focus; idle panel emits no comet cells.
  - `packages/tina_engine/test/agent/sub_agent_scheduler_test.dart`
    "a panelized job drives its panel host activity cue" — [true, false].
- Suites: root all green; tina_console 745/745; tina_engine all green except
  the documented pre-existing sandbox failure (process_tree_test
  "kills a backgrounded descendant…").
- `dart analyze`: 30 issues before and after — zero new (all pre-existing,
  in tool/ render helpers and unrelated files).
- Live from a clean restart: `tool/y4qn_hunt.sh` (stub scenario `y4qn_busy`,
  ~20 s paced stream; spawn side panel; cycle focus away mid-turn; queue a
  second message) → HEALTHY: busy+unfocused comet samples 2/2/2,
  idle+unfocused 0/0, queued turn ran while unfocused.

Side finding filed separately: `/spawn`'s model picker is empty for
custom (user-defined) providers — no model catalog, so the overlay shows
"(no items available)" and swallows keys until Esc (tin-9x4m).
