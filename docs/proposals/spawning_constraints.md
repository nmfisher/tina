# Proposal: constrain spawning — no workflows, 3 subagents, render-only panels, main-panel approvals

Status: proposal, not implemented. Scope decision: workflow launching is
turned OFF for the main agent (revisit later); subagent delegation stays.
Handoff brief — an implementer should be able to execute it without further
design decisions.

## What exists today (verified in code)

- **Subagents**: `SubAgentScheduler`
  (`packages/tina_engine/lib/src/agent/sub_agent_scheduler.dart`). Any agent
  with the `delegate` tool spawns jobs. Concurrency: `AgentQuota(maxLive:)`
  from `maxConcurrent` — default **6** (scheduler constructor). Depth:
  `maxDepth` — default 3. Non-panel subagents get `_autoDenyAsker` (every
  permission ask auto-denied). Panelized subagents
  (`subAgentSessionFactory` path) build their `Agent` with
  `asker: host.askPermission` (the panel host's asker, wired in
  `lib/tui_coordinator.dart` around line 1875).
- **Panels**: the subagent persistence hook (`tui_coordinator.dart`
  ~1797–1839) mints a conversation + `_makeSpawnedHost` + `_buildSpawnPanel`,
  sets `job.panelHost` / `wirePanelFocus` / `panelSink` (a `BusSink`). Focused
  spawn panels bind the shared editor, which is why subagent panels are
  currently interactive.
- **Workflows**: `LaunchWorkflowTool` / `StopWorkflowTool`
  (`packages/tina_app/lib/src/workflows/launch_workflow_tool.dart`) are added
  to the main agent in `buildAgent`
  (`packages/tina_app/lib/src/composition/agent_composition.dart:243–252`)
  only when `supervisor != null && config.enableWorkflow`. `launch_workflow`
  stays on the default `ask` in the main policy; `stop_workflow` is
  pre-allowed. The supervisor itself is built in `tui_coordinator.dart` ~594,
  unconditionally.
- **Auto-mode**: `modeAwareAsker`
  (`packages/tina_engine/lib/src/permissions/mode_aware_asker.dart`) wraps an
  asker when a `classifier` is wired (main agent: `buildAgent` ~384–392;
  workflow runs: `tui_coordinator.dart` ~564–592). In `PermissionMode.auto`
  the classifier decides; on classifier failure it falls back to the wrapped
  asker.

## Change 1 — main agent cannot launch workflows

In `buildAgent`, remove the `if (supervisor != null && config.enableWorkflow)`
block (`agent_composition.dart:243–252`) that appends
`LaunchWorkflowTool` + `StopWorkflowTool`. The classes stay in the tree
(revisit later); the supervisor, run panels, and
`SessionController.injectWorkflowResult` stay mounted — with no tool, the
agent can never trigger them. `/workflow` user commands are unaffected.

Also strip the workflow-launch phrasing from `_mainIdentity`
(`packages/tina_engine/lib/src/agent/agent_pipeline.dart`) and stop passing
`workflowEnabled: config.enableWorkflow` into `resolveMainPrompt`, so the
model is not told about a tool it does not have.

Docs: `docs/features/manager_loop.md` and `docs/features/default_workflow.md`
describe `launch_workflow` as the main agent's execution path — add a note
that it is currently disabled.

## Change 2 — cap concurrent subagents (default 3)

`SubAgentScheduler` constructor: `maxConcurrent: 6` → `3`. The quota already
threads through `AgentQuota(maxLive:)` and `createScheduler`; nothing else to
change. Update tests that assert the default 6; keep any that pass an explicit
quota.

**Landed 2026-09-25 (`306837c`).** Reality check: production never uses the
scheduler's constructor default — `execution_runtime.dart` builds the quota
from `config.maxSubAgentConcurrency`, so the real cap is the config chain
(CLI default → `parseLimit` file override → `RuntimeConfig`). All six
defaults moved together: `lib/config.dart` (CLI default, `parseLimit`
fallback, help `defaultsTo`), `RuntimeConfig`, `AgentQuota`, the scheduler
constructor. `[limits] max_sub_agent_concurrency` in the user config still
overrides; `--yolo` still lifts the cap entirely.

## Change 3 — subagent panels are render-only

The panel keeps: the streamed transcript, the busy cue, the done cue, PgUp/
PgDn scroll, `x`/Ctrl+X close. It loses: editor binding on focus — typed text
can never enter a subagent panel.

Mechanism (coordinator layer, `lib/tui_coordinator.dart` + `lib/tui/`):
in the persistence hook, stop invoking `wirePanelFocus` so a subagent panel
never becomes the active conversation — focus moves highlight only. The
engine's null guard then routes the job through the telemetry-only build, so
keep `job.panelHost` set and pass a no-op `wirePanelFocus` if the factory
branch must stay (decide by reading `_runAgent`'s guard order). Precedent:
workflow run panels (`RunPanelContent`) are already input-less spawned-style
frames — reuse that content type for subagent panels, keeping the
spawned-frame visuals (label, comet, ✖/✔ settle).

## Change 4 — subagents inherit permissions + auto-mode

Thread the main conversation's **resolved asker** (post-`modeAwareAsker`
wrap) down to spawned subagents, for both build paths:

- `AgentToolContext` gains `PermissionAsker? inheritedAsker`; `DelegateTool`
  passes it to `spawn()`; `spawn()` stores it on `SubAgentJob`.
- Plain build (`_runAgent`): use `ctx.inheritedAsker ?? _autoDenyAsker`.
- Panelized build: pass the inherited asker into the
  `SubAgentSessionFactory` (signature gains the param) instead of
  `host.askPermission`.

Because the inherited asker IS the mode-aware wrapper (it consults
`policy.mode` per call), a session in auto mode gives every subagent
classifier-first decisions with the main-panel prompt as fallback — no
separate auto-mode flag needed. Subagents keep deriving their own policy from
their tool profile as today; only the asker changes.

## Change 5 — subagent asks surface in the main panel, flagged

The fallback asker inside the inherited wrap must render in the MAIN panel,
never the subagent panel (which is render-only now).

- `runPermissionApproval` (`lib/tui/permission_approval.dart`) gains
  `String? originLabel`; the approval card renders it as a prefix/chip on the
  title line (`┌ [sub-agent: <label>] <title> · awaiting approval`).
- The coordinator's main `TuiConversationHost.askPermission` already routes
  to `runPermissionApproval` — the subagent ask rides it via the inherited
  asker's fallback.
- Cancellation: `prompt.cancelSignal` already carries the job's cancel, so a
  cancelled/finished subagent unwinds its pending ask (deny-once) with no
  extra wiring.

## Tests

- Scheduler: default maxLive == 3; update default-asserting tests.
- Delegate/`AgentToolContext`: inherited asker flows to `spawn` and is used by
  both build paths; `_autoDenyAsker` only when none supplied.
- Coordinator: subagent panel never binds the editor; approval surfaces in
  the main panel with the `[sub-agent: …]` flag; run panels unchanged.
- `buildAgent`: no workflow tools in the main set; identity prompt carries no
  launch phrasing.
- Suites: `packages/tina_engine/test`, `packages/tina_app/test`, and the
  root `test/` suites covering the coordinator/TUI.

## Warnings

- `SubAgentSessionFactory` signature change — update the coordinator closure
  (`tui_coordinator.dart` ~1852) and every test double.
- Do not delete the `WorkflowSupervisor`/run-panel machinery — only the
  agent-facing tools go.
- The subagent's `panelHost` still needs a `HostInterface` for activity/notice
  routing even though it never asks; don't null it.
- A remembered "always allow" from a subagent ask lands in the subagent's
  policy copy, not the main session cascade — accepted for now; revisit with
  workflows.
- Line anchors drift: grep for the code, don't trust the numbers.
- One commit per change; style `feat(engine|tui|session): …`.
