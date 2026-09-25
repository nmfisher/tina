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
(`lib/composition/plan_ui.dart`), it is persistent rather than per call, and it
is cooperative rather than blocking: nothing pauses. This page documents the
plan mechanism and where the boundary between the two sits.

## The value

Plan approval is a field on the plan itself:

```dart
enum PlanApproval { none, requested, approved, rejected }
```

(`plan_store.dart:11`.) The `PlanStore` holds one plan per conversation and
owns every transition:

- The **agent** moves a plan to `requested` by calling `update_plan` with
  `approval: "requested"` (`store.requestApproval`, `plan_plugin.dart:155`).
- Only the **user** moves it to `approved` or `rejected` — via
  `/plan approve|reject` (`plan_plugin.dart:263-265`) or the plan overlay
  (`lib/tui/plan_overlay.dart:380,388`). See
  [Plan overlay](../proposals/plan_overlay.md) for that surface; this page
  does not duplicate it.
- An update that changes item **content** resets approval to `none`
  (`plan_store.dart:153-157`): an edited plan must be approved again. A
  state-only update (progress ticks) preserves the decision.

## How it flows

The agent asks by calling its plan tool; the user answers through a command or
the overlay. The model never sees a modal and the user never sees a permission
prompt. Between the two, the state sits in the store and is re-injected into
the agent's context on every request: `PlanMiddleware` appends a
`<current-plan>` section to the system prompt each turn
(`plan_plugin.dart:21-47`), telling the model what the approval is and what to
do — including, while a request is pending, to *wait*
(`plan_plugin.dart:60-62`).

That is the polarity difference from tool approval. A tool ask is a blocking
request for a single action; the executor cannot proceed without an answer. A
plan ask is persisted state that outlives the turn; the agent reads the
current answer from its context whenever it next runs. Both sides stay
cooperative, and a request can sit pending indefinitely without anybody
hanging.

## Why plan approval is not governed by tool approval

`update_plan` implements `LocalControlTool`. The tool executor short-circuits
exactly those tools — the decision is hardcoded `PermissionDecision.allow`
without consulting the policy or the asker (`tool_executor.dart:445-447`;
`tool.dart:65`; the tool's own doc comment at `plan_plugin.dart:80-83`). The
guard chain (phase guards and the rest) still applies; the permission ask does
not.

This is why `--yolo` cannot govern plan approval and why the two mechanisms
cannot be treated as one: the plan gate never travels the ordinary
tool-permission path, so no permission flag, mode, or rule can reach it.
Approval state moves only through the store transitions listed above. (The
`LocalControlTool` shortcut was designed for state flips like this one — a
tool that only mutates plugin-local orchestration state, with no capability
escalation. See ticket tin-p4wm for the standing note that a `--deny` naming
such a tool is inert.)

## A plugin — but not purely a plugin

`planUiPlugin` (`lib/composition/plan_ui.dart:13`) provides the shared
`PlanStore` service, the status-strip source and renderer, and the `/plan`
command. That is the plugin part.

The agent-facing pieces are not scope contributions. A shared plugin scope
spans every live conversation and cannot tell which conversation a turn
belongs to, so core `buildAgent` mints the `update_plan` tool and the request
middleware per conversation, reading the store the plugin provides under
`planStoreServiceKey` (`agent_composition.dart:191-203`; note at
`plan_ui.dart:8-12`). The plugin contributes the service and the UI; core
builds the agent-facing pieces from it. There is no plugin descriptor for tool
approval at all — the contrast is deliberate, see
[the plugin architecture proposal](../proposals/plugin_architecture.md).

## The decided boundary

Plan approval stays a plugin. Core owns the permission decision: a plugin must
not re-derive policy — it may not decide who answers an approval, or what the
answer means. The intended shape is that plugins get one narrow read-only door
into the decision — "may I ask? and can anyone answer?" — and the plugin asks
while core decides.

Current status on `main`: the door does not exist, and the plan gate consults
nothing outside its own plugin. A checked-but-unmerged change (see the gaps
below) narrows this, but by moving the re-derivation into the plugin rather
than behind a core door.

## Known gaps

These are gaps, not settled behaviour. Do not rely on them as design. Each
has a candidate fix checked in on the `asb/plan-approval-yolo` branch (open
PR #61); none of it is merged, so nothing below describes `main` as it
stands.

1. **The read-only door does not exist yet.** Nothing asks the policy "may a
   plan approval be requested here?" or "can anyone answer?". Because the
   door is missing, nothing reconciles the plan gate with the permission
   posture at all — the two simply run side by side. PR #61 sketches a first
   version of the door, but in the wrong place: it is the *plugin's own*
   `resolveApprovalMode` reading the policy and host (`plan_plugin.dart`
   there), i.e. the plugin re-deriving the decision itself, not core
   answering through a door. The decided shape — a door owned by core that a
   plugin may only ask — is still unbuilt.

2. **The plan gate re-derives the permission posture.** The decision the
   door should provide exists, and the policy already knows how to answer
   it: `allowAllByDefault` (`--yolo`, `policy.dart:250`) is exactly "skip
   permission prompts". PR #61 has `resolveApprovalMode` read it — but from
   inside the plugin, duplicating rather than consuming the decision. Until
   the posture travels through core, the same fact lives in two places and
   can drift.

3. **"Who can answer" is expressed in three places, with two polarities.**
   When no user is available, each mechanism answers on its own:
   `HeadlessHost.askPermission` auto-**denies** tool asks — fail-closed,
   never run an unapproved command (`headless_host.dart:49-80`); the
   sub-agent scheduler's `_autoDenyAsker` does the same for delegated agents
   (`sub_agent_scheduler.dart:1352`); and a background TUI conversation
   denies its own asks (`tui_conversation_host.dart:241-261`). A plan
   request that nobody can answer does not deny — it stays `requested` and
   the model is told to wait: fail-open, because a run that cannot structure
   its work is stuck. Both polarities are deliberate: a tool call without a
   human must not execute; a plan without a human must not wedge the run.
   PR #61 adds `HostInterface.canAnswerQuestions` (default true,
   `HeadlessHost` false) so the host can *say* "nobody can answer" — a
   fourth expression, and one that belongs behind the core door rather than
   beside the other three.

4. **Auto-granted plans are indistinguishable from human sign-off.** A
   classifier-answered tool grant records that no human decided it —
   `GrantSource.classifier` / `decidedBy: 'classifier'`
   (`mode_aware_asker.dart:43-49`, `prompt.dart:278-279`). The plan store
   has no equivalent: there is no third value for "granted without a
   human". PR #61's auto-grant path therefore stores `approved` — identical
   to a human approval — and the status strip renders `approved`. The
   message to the model is honest; the stored state is not.
