# Handoff: split `tui_coordinator.dart`

Status: ready for handoff. This is revision 2. It replaces the earlier
two-part plan with a ladder of eight small commits, shaped by the verified
call graph (see "Why eight commits"). The work is a mechanical split of
existing behavior — not a redesign of the TUI or the engine.

## Goal

Reduce the size and responsibility of `lib/tui_coordinator.dart` without
changing TUI behavior, persistence, focus rules, or panel lifecycle.

Rules for every commit:

- One commit per step below. Never combine steps.
- Move code before changing code. These commits only move; dedup ideas
  (see "Explicitly out of scope") are not part of this work.
- Keep all existing public interfaces and user commands stable.
- After every commit: `dart analyze` clean and the focused suites (bottom
  of this file) green. Run the full `dart test` before pushing.

## Current state

These extractions are already committed. Do not repeat them:

- Rate-limit spacing policy is in
  `packages/tina_engine/lib/src/llm/provider_rate_limit.dart`.
- History replay is in `packages/tina_engine/lib/src/host/history_replay.dart`.
- Model curation (`disabledModelRefsFor`) and the spawn MRU are in
  `lib/config/provider_selection.dart` and `lib/config/spawn_mru.dart`.
- Generic tree ordering (`orderByTree`) is in `lib/tui/tree_order.dart`.
- Settings application is in `lib/composition/settings_apply.dart`.
- Input-state wiring is in `lib/tui/coordinator_input_handlers.dart`.
- Transcript folding is in `lib/tui/transcript_fold.dart`.
- Workflow overlay handlers are in `lib/tui/workflow_overlay_handlers.dart`.
- Panel geometry, focus state, and shared-input relocation are in
  `lib/tui/panel_manager.dart`.
- Conversation-to-panel binding is in
  `lib/tui/conversation_panel_coordinator.dart`.
- Run panels are built through `lib/tui/panel_host.dart` and
  `lib/tui/run_panel_host.dart`.
- Provider-backed conversation creation (`spawn`, `branch`,
  `ConversationOperationFailure`) is owned by `ConversationOperations` in
  `packages/tina_app/lib/src/session/conversation_operations.dart`,
  exported from `package:tina_app/tina_app.dart`.

The rejected rate-limit ideas are also out of scope: retry-budget compounding,
the `typesafe` HTTP path that bypasses the limiter, and held-permit release
behavior.

`HostMessageStyle` is defined in
`packages/tina_engine/lib/src/host/host_interface.dart` and re-exported
through `package:tina_engine/tina_engine.dart`.

## Why eight commits

The remaining inline code was checked for call edges. Result: the graph is
nearly flat. Only `createSideConversation` calls other inline pieces
(`pickTarget`, `operations`, `_buildSpawnPanel`). Everything else is
independent and can move alone:

| Inline code | Verified location | Calls (inline) | Called by (inline) |
| --- | --- | --- | --- |
| `controller.openSessionPicker` | ~1178 | — | — |
| `controller.openPrompts` | ~1302 | — | — |
| `renderImageToPanel` + `openImage` + `imageRenderer.coordinate` | ~1338–1415 | — | — |
| `_makeSpawnedHost` | ~1596 | — | `ConversationOperations` `hostFactory`, `RunPanelHost.makeSinkHost`, the sub-agent factory (~1776) |
| `_buildSpawnPanel` | ~1631 | — | sub-agent factory (~1777), `panelizeRestoredConversation`, `createSideConversation` (~2017) |
| `_closeRunPanel` / `_openRunPanel` | ~1696–1731 | — | `handleWorkflowLaunch` (~1734), run panel close key |
| `panelizeRestoredConversation` | ~1884 | `_buildSpawnPanel` | the restore loop (~1900) |
| `pickSpawnedTarget` | ~1910 | — | `pickTarget` resolution (~1962) |
| `createSideConversation` | ~1974 | `pickTarget`, `operations`, `_buildSpawnPanel` | `controller.openSpawn` / `openBranch` |

Line numbers drift as the file is edited. Use the symbols, not the lines.

`panelizeRestoredConversation` is a 12-line wrapper over `_buildSpawnPanel`
plus restore-loop glue; it stays in the coordinator. `PanelHost` and
`RunPanelHost` construction (~1681–1694) is composition glue, not logic;
it stays too. What moves is only what the table lists.

## Non-negotiable behavior

- The session picker uses the current active session and current live sessions.
  A disk session resumes through the controller, never by rebuilding state.
- A failed disk listing is silent and yields an empty disk list.
- Prompts are restart-only. A successful write must say Tina must restart.
- Image paths resolve against `Directory.current.path`; absolute paths are
  kept. A one-shot paint — streaming chat or `/clear` repaints over it.
- `<3x3` interiors render nothing; an image taller than the interior anchors
  at the interior top, not underflow.
- `/image` and the `render_image` agent tool receive the same renderer
  function; teardown resets the pipeline coordinate with `coordinate(null)`.
- The first spawned panel sets `initialHost.stayAttachedWhenInactive` and then
  runs the canonical resize sequence (`handleResize(split: true,
  drawInfoFrame: false)`) before the first frame binds. The "first panel"
  check reads `panelManager.hasSpawnedFrames` BEFORE adding.
- The spawn tree stores `parentOf` and `baseLabel` for every spawned
  conversation. Keep the DFS ordering and label restoration.
- A run panel opens synchronously inside the supervisor's `onLaunch` hook —
  the sink is installed before the first run event can arrive — and must not
  steal input focus.
- Closing a run panel clears `WorkflowRun.onFinished` before teardown.
- Restored conversations are panelized before their history is replayed.
- `/spawn` and `/branch` share the same target picker and profile picker.
- A valid persisted conversation survives a failed panel presentation. Report
  the error; do not delete or roll back the conversation.
- The first error path in `createSideConversation` reports through the captured
  `sourceHost`, because the active session may change while creation waits.
- A conversation created in another session is not presented here; it reports
  where it was created.
- A branch replays its history only after the panel is attached.
- The scheduler sub-agent persistence hook and `scheduler.subAgentSessionFactory`
  are adjacent to this work but are not moved. Do not change their ordering or
  driver-resolution behavior.

## The ladder

Destination files (unchanged from revision 1; both already named in the plan):

- `lib/tui/coordinator_overlay_handlers.dart` — steps 1–3
- `lib/tui/panel_spawn_coordinator.dart` — steps 4–8

Each step defines an explicit dependency object. Do not pass the whole
coordinator. Start each deps type with only what that step's handlers use and
extend it in later steps — never add something speculatively.

### Step 0 (optional, separate commit) — extract SpawnTree

`SpawnTree` (lines ~80–129 of the coordinator) is a pure data structure:
root id, `parentOf`, `baseLabel`, cycle-guarded `depthOf`, DFS `ordered()`.
Its only panel taints are `relabelPanel` (touches `PanelFrame`) and
`ordered()` reading `conversationId`.

- Move `SpawnTree` + `lib/tui/tree_order.dart` into a shared module, with
  direct unit tests (depth, cycle guard, pre-order, relabel bookkeeping).
- Genericize `ordered()` over an id/parent accessor so it has no `PanelFrame`
  import; keep a thin typed wrapper at the call sites if it reads better.
- A standalone package (`fuzzy_ranker`-style) is possible but has no second
  consumer today — a shared module captures the value; revisit packaging
  later. This step can also be deferred past step 8 without blocking anything.

### Step 1 — image renderer

Move `renderImageToPanel` and the `openImage` wiring out of the closure.
Split the fit math (aspect fit to the cell budget, `pxPerCell`, bottom-margin
row, top-anchor rule) into a pure function in the new module so it gets unit
tests without a fake screen; the moved handler keeps the decode + blit.

```dart
typedef PanelImageRenderer = Future<String?> Function(String path);

PanelImageRenderer makePanelImageRenderer(CoordinatorOverlayDeps deps);
```

The coordinator keeps the wiring shape: it assigns
`controller.openImage`, passes the identical function to
`pipeline.imageRenderer.coordinate`, and resets with `coordinate(null)` at
teardown. One renderer instance for both consumers.

New deps (start of `CoordinatorOverlayDeps`): `screen`, `focusManager`,
`primaryPanel`, `contentCoordinator.surfaceOf` as a function field.

Tests: missing file message; undecodable message; `<3x3` renders nothing;
fit math outputs (width budget, height round, anchor row) as a pure table;
normal render calls `renderImageAbsolute` with fitted size, position, and the
panel's chat surface; taller-than-interior anchors at the top; errors reach
the active host; `/image` and the agent tool share one function.

### Step 2 — session picker

Move `openSessionPicker`. Same deps object, extended with `sessionManager`,
`store`, `editor`, `refreshSessionMenu`, and a `switchSession`/
`resumeIntoActive` seam if direct controller capture reads worse than an
explicit callback. Keep the wiring in the coordinator:
`controller.openSessionPicker = () => openSessionPicker(deps)`.

Tests: live and disk entries reach the picker in the same order and shape;
failed disk listing yields an empty list without throwing; cancel leaves the
active session unchanged; a live pick calls `switchSession`; a disk pick
calls `resumeIntoActive` and refreshes the menu.

### Step 3 — prompts

Move `openPrompts`. Deps additions: `app` (for `environment.env` and
`loadUserConfig`), `pipeline`. Keep `HostMessageStyle` real — no invented
type names; import it from `package:tina_engine/tina_engine.dart`.

Tests: cancel leaves the host unchanged; a write shows the restart message;
no write shows `(prompts unchanged)`; `ConfigWriteException` shows a warning
and no success message.

### Step 4 — spawned host factory

Move `_makeSpawnedHost` as a top-level function over deps; update the three
call sites (ConversationOperations `hostFactory`, `RunPanelHost`
`makeSinkHost`, the sub-agent factory).

```dart
TuiConversationHost makeSpawnedHost(PanelSpawnDeps deps, String conversationId,
    {String role = 'main'});
```

New deps (start of `PanelSpawnDeps`): `screen`, `editor`, `app`
(`pluginScope`, `regexSuggester`), `config.sandboxOffReason`, `policy`,
`_menuBarEnabled` as a bool field.

Tests: returns a detached, inactive, non-primary host with the given role
label, disabled spinner, and the shared policy.

### Step 5 — spawn panel builder

Move `_buildSpawnPanel` the same way. Deps additions: `tree`, `panelManager`,
`contentCoordinator`, `resizeCoordinator`, `initialHost`.

Tests: first panel splits the layout and sets `stayAttachedWhenInactive`;
a second panel does not split again; `parentOf`/`baseLabel` are recorded;
the frame is bound, laid out, and content relayed.

### Step 6 — run panels

Move `_openRunPanel`/`_closeRunPanel`. `PanelHost`/`RunPanelHost`
construction stays in the coordinator and is passed in via deps
(`runPanels`, `supervisor`); `handleWorkflowLaunch = openRunPanel` wiring
stays in the coordinator too.

Tests: the run sink is installed synchronously (before any run event); the
busy cue is set from `run.isRunning`; `run.onFinished` is assigned; closing
clears `onFinished` before teardown; `s` calls `supervisor.stop`; `x` runs
the full close path.

### Step 7 — target picker

Move `pickSpawnedTarget`. The `pickTarget = spawnTargetPicker ??
pickSpawnedTarget` resolution stays in the coordinator (it is the test
injection seam). Deps additions: `scheduler.registry` access,
`loadUserConfig`, `sessionManager` (already present from step 2's object —
share one `PanelSpawnDeps`; do not fork a second deps type).

Tests: no providers configured shows the `/settings` warning and returns
null; MRU is seeded and recorded around the overlay; cancel at either
overlay returns null; an injected `spawnTargetPicker` bypasses the overlays.

### Step 8 — side conversation (last)

Move `createSideConversation` and its `openSpawn`/`openBranch` wiring. This
is the only step whose code calls other moved pieces (`pickTarget`,
`operations`, `buildSpawnPanel`), which is why it is last. Deps additions:
`operations`, `replayHistory`, `focusManager`, `loadConfig`,
`reloadConfigProviders`, `sideConversationPresenter`, `spawnTargetPicker`.

The coordinator keeps: constructing `ConversationOperations(... hostFactory:
makeSpawnedHost ...)` where it is today, and assigning
`controller.openSpawn`/`openBranch`.

Tests: creation failure reports through the captured `sourceHost` even if
the active session changed during the await; a saved conversation survives a
panel-attach failure with the existing message; a conversation created in
another session reports there and is not presented; a branch replays history
only after attach; `/spawn` and `/branch` share one picker.

### A note on the original Part-2 class

Revision 1 sketched a `PanelSpawnCoordinator` class. With the graph this
flat, a class is optional: top-level functions over `PanelSpawnDeps` are
enough, and a small wiring function can replace the class entirely. Reintroduce
the class only if a single hand-around object proves useful (for example as
the `hostFactory` carrier).

## Explicitly out of scope

- The visible duplication between `pickSpawnedTarget` and `openModelPicker`
  (~2038: same configured-provider guard, same `disabledModelRefsFor`
  block). Tempting during step 7; do not touch it in this work.
- The scheduler sub-agent persistence hook and `subAgentSessionFactory`.
- Any behavior change, any renamed user command, any new abstraction beyond
  the two deps types.
- Packaging the image fit math: it is tina-specific heuristics (6 px/cell),
  worth a pure function, not a package.

## Landing order

1. Commit this plan. (done — 4372081; this revision supersedes it)
2. Optional step 0 (SpawnTree module), alone.
3. Steps 1–4 in any order (they are mutually independent), each alone.
4. Step 5, then 6, then 7, each alone.
5. Step 8 last — it is the only step with intra-plan dependencies.

Every commit: `dart analyze` clean, focused suites green:

```sh
dart test test/tui_coordinator_test.dart \
  test/tui/conversation_panel_coordinator_test.dart \
  test/tui/workflow_overlay_handlers_test.dart
```

Run the full `dart test` before pushing. Add each step's direct unit-test
file under `test/tui/` in the same commit as the move.
