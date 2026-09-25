# Plan approval

Tina has two approval mechanisms. They look similar and are different in kind.

**Tool approval** asks "may I run this?". It lives in the engine's permission
layer — see [Permission rules](permission_rules.md) and the
[`permissions/` section of ARCHITECTURE.md](../../ARCHITECTURE.md#packages/tina_engine/lib/src/permissions/--gating).
It is per call and synchronous: the tool executor pauses the turn until a
`PermissionResponse` answers the ask (`tool_executor.dart:445-447` runs
`policy.check()` and waits on the asker before anything executes).

**Plan approval** asks "do you approve this plan of work?". It is not part of
the permission layer at all. It lives in the `tina.plan` plugin
(`lib/composition/plan_ui.dart`), it is persistent rather than per call, and
it is cooperative rather than blocking: nothing pauses. Since v0.8.30 it also
consults the permission posture — but through a plugin-owned read, not the
permission path itself (details below). This page documents the
plan mechanism and where the boundary between the two sits.

## The value

Plan approval is a field on the plan itself:

```dart
enum PlanApproval { none, requested, approved, rejected }
```

(`plan_store.dart:11`.) The `PlanStore` holds one plan per conversation and
owns every transition:

- The **agent** moves a plan to `requested` by calling `update_plan` with
  `approval: "requested"` (`store.requestApproval`,
  `plan_plugin.dart:235`, `plan_store.dart:168-169`).
- Normally only the **user** moves it to `approved` or `rejected` — via
  `/plan approve|reject` (`plan_plugin.dart:355-357`) or the plan overlay
  (`lib/tui/plan_overlay.dart:377-388`). The one exception is the
  unattended/yolo auto-grant documented below, where the *tool* writes
  `approved` without a user (`plan_plugin.dart:218-224`). See
  [Plan overlay](../proposals/plan_overlay.md) for that surface; this page
  does not duplicate it.
- An update that changes item **content** resets approval to `none`
  (`plan_store.dart:150-157`): an edited plan must be approved again. A
  state-only update (progress ticks) preserves the decision.

## How it flows

The agent asks by calling its plan tool; the user answers through a command or
the overlay. The model never sees a modal and the user never sees a permission
prompt. Between the two, the state sits in the store and is re-injected into
the agent's context on every request: `PlanMiddleware` appends a
`<current-plan>` section to the system prompt each turn
(`plan_plugin.dart:21-60`), telling the model what the approval is and what
to do — including, while a request pends in an interactive run, to *wait*
(`plan_plugin.dart:78-80`). An unattended or yolo run never gets that wait
instruction: the same section says to proceed (`plan_plugin.dart:73-76`).

That is the polarity difference from tool approval. A tool ask is a blocking
request for a single action; the executor cannot proceed without an answer,
and a host with no human denies it. A plan ask is persisted state that
outlives the turn; the agent reads the current answer from its context
whenever it next runs. The remaining asymmetry — when no human exists, the
tool ask *denies* while the plan ask *auto-grants* — is deliberate (see
[Known gaps](#known-gaps), item 3) and rests on the same distinction: an
unapproved action must not execute, but a run must not wedge on its own
bookkeeping.

## Why plan approval is not governed by tool approval

`update_plan` implements `LocalControlTool`. The tool executor short-circuits
exactly those tools — the decision is hardcoded `PermissionDecision.allow`
without consulting the policy or the asker (`tool_executor.dart:445-447`;
`tool.dart:65`; the tool's own doc comment at `plan_plugin.dart:98-101`). The
guard chain (phase guards and the rest) still applies; the permission ask does
not.

This is why `--yolo` cannot govern plan approval *through the permission
path* and why the two mechanisms cannot be treated as one: the plan gate
never travels the ordinary tool-permission path, so no permission flag, mode,
or rule can reach it there. Approval state moves only through the store
transitions listed above. (`--yolo` reaches the plan gate by a separate,
deliberate route — the plugin's posture read documented below — not through
the executor.) The `LocalControlTool` shortcut was designed for state flips
like this one — a tool that only mutates plugin-local orchestration state,
with no capability escalation. See ticket tin-p4wm for the standing note
that a `--deny` naming such a tool is inert.

## A plugin — but not purely a plugin

`planUiPlugin` (`lib/composition/plan_ui.dart:13`) provides the shared
`PlanStore` service, the status-strip source and renderer, and the `/plan`
command. That is the plugin part.

The agent-facing pieces are not scope contributions. A shared plugin scope
spans every live conversation and cannot tell which conversation a turn
belongs to, so core `buildAgent` mints the `update_plan` tool and the request
middleware per conversation, reading the store the plugin provides under
`planStoreServiceKey` and wiring the conversation's policy and host into both
(`agent_composition.dart:198-220`; note at `plan_ui.dart:8-12`). The plugin
contributes the service and the UI; core builds the agent-facing pieces from
it. There is no plugin descriptor for tool
approval at all — the contrast is deliberate, see
[the plugin architecture proposal](../proposals/plugin_architecture.md).

### The posture read (current behaviour)

Since v0.8.30, the per-conversation pieces carry the conversation's
`PermissionPolicy` and `HostInterface`, and `PlanTool.resolveApprovalMode`
resolves a `PlanApprovalMode` from them (the mode enum at
`plan_plugin.dart:117`, the resolver at `plan_plugin.dart:142-149`):
`autoGrant` when
`policy.allowAllByDefault` (the `--yolo` posture) or the host cannot answer
questions (`!host.canAnswerQuestions` — headless `--prompt`/`--workflow` has
neither a `/plan` nor an overlay); `interactive` otherwise. Under
`interactive`, a `requested` ask parks the plan in the store and the model is
told to wait. Under `autoGrant`, the tool approves in place — the store
never sits in `requested` — and both the tool result and the middleware
section tell the model to proceed (`plan_plugin.dart:218-224`,
`plan_plugin.dart:75-76`, `plan_plugin.dart:280-282`).

Note where this resolution lives: inside the plugin. Core wires the *inputs*
(policy, host) but the plugin owns the *rule*. That is the drift the decided
boundary rules out, and it is the subject of
[the posture-door proposal](../proposals/plugin_posture_door.md).

## The decided boundary

Plan approval stays a plugin. Core owns the permission decision: a plugin must
not re-derive policy — it may not decide who answers an approval, or what the
answer means. The intended shape is that plugins get one narrow read-only door
into the decision — "may I ask? and can anyone answer?" — and the plugin asks
while core decides.

Current status on `main` (since v0.8.30, PR #61): the plan gate consults
policy and host through a helper owned by the plugin itself — the posture
question is answered, but by the wrong party. The narrow core-owned door that
would let the plugin *ask* rather than *derive* is still unbuilt (see the
proposal [The plugin posture door](../proposals/plugin_posture_door.md) and
the gaps below).

## Known gaps

These are gaps, not settled design. The fail-open stall is fixed (as of
v0.8.30), but the fix moved policy re-derivation into the plugin rather than
behind a core door; the structural items below remain.

1. **The read-only door does not exist yet.** The plugin never asks core "may
   a plan approval be requested here?" or "can anyone answer?". The
   reconciliation the plan gate performs is real, but it runs inside the
   plugin: `resolveApprovalMode` is `PlanTool`'s own static
   (`plan_plugin.dart:142-149`), called from the plugin's constructor
   (`plan_plugin.dart:156`) — the plugin re-deriving the decision itself, not
   core answering through a door. The decided shape — a door owned by core
   that a plugin may only ask — is still unbuilt.

2. **The plan gate re-derives the permission posture.** The decision the door
   should provide exists, and the policy already knows how to answer it:
   `allowAllByDefault` (`--yolo`, `policy.dart:250`) is exactly "skip
   permission prompts". `resolveApprovalMode` reads it directly
   (`plan_plugin.dart:146-147`) — duplicating rather than consuming the
   decision. Until the posture travels through a core-owned answer, the same
   fact lives in two places and can drift.

3. **"Who can answer" is expressed in three deny dialects, and the plan gate
   answers in the opposite polarity.**
   When no user is available, each tool-side mechanism denies on its own:
   `HeadlessHost.askPermission` auto-**denies** tool asks — fail-closed,
   never run an unapproved command (`headless_host.dart:55-88`); the
   sub-agent scheduler's `_autoDenyAsker` does the same for delegated agents
   (`sub_agent_scheduler.dart:1352-1353`); and a background TUI conversation
   denies its own asks (`tui_conversation_host.dart:244-262`). A plan
   request that nobody can answer does not deny — under `autoGrant` it is
   approved in place and the model is told to proceed
   (`plan_plugin.dart:218-224`): fail-open, because a run that cannot
   structure its work is stuck. Both polarities are deliberate: a tool call
   without a human must not execute; a plan without a human must not wedge
   the run. `HostInterface.canAnswerQuestions` (default true,
   `host_interface.dart:49`; `HeadlessHost` false,
   `headless_host.dart:52`) is the host *saying* "nobody can answer" — a
   fourth expression, consumed by the plugin's resolver rather than behind
   the core door.

4. **Auto-granted plans are indistinguishable from human sign-off.** A
   classifier-answered tool grant records that no human decided it —
   `GrantSource.classifier` / `decidedBy: 'classifier'`
   (`mode_aware_asker.dart:46-48`, `prompt.dart:274-286`). The plan store
   records no source: nothing in `PlanApproval` or `Plan` says whether a
   human granted it. The auto-grant path therefore stores plain `approved`
   (`plan_plugin.dart:218-224`) — identical to a human approval — and the
   strip (`plan_status_renderer.dart` has no approval-vs-auto distinction)
   and the overlay badge (`plan_overlay.dart:164-169`) render `approved`.
   The message to the model is honest (the tool result says "approved
   automatically", `plan_plugin.dart:280-282`); the stored state is not.
