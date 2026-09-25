# Handoff: split `tui_coordinator.dart`

Status: ready for handoff. This document describes the next coordinator work.
The work is a mechanical split of existing behavior. It is not a redesign of the
TUI or the engine.

## Goal

Reduce the size and responsibility of `lib/tui_coordinator.dart` without
changing TUI behavior, persistence, focus rules, or panel lifecycle.

The plan has two parts, landed as two separate commits:

1. Move the small overlay and image handlers into one focused module.
2. Move panel creation, spawned conversations, and workflow run panels into a
   separate coordinator.

Keep all existing public interfaces and user commands stable. Move code before
changing code. Never combine the two parts in one commit.

## Current state

These extractions are already committed. Do not repeat them:

- Rate-limit spacing policy is in
  `packages/tina_engine/lib/src/llm/provider_rate_limit.dart`.
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

The rejected rate-limit ideas are also out of scope: retry-budget compounding,
the `typesafe` HTTP path that bypasses the limiter, and held-permit release
behavior.

The code still inline in `lib/tui_coordinator.dart` (all inside
`TuiCoordinator.create`):

| Inline code | Verified location | Behavior |
| --- | --- | --- |
| `controller.openSessionPicker` | ~line 1178 | Builds live entries from `sessionManager.listSessions()` and disk entries from `store.listSessions()` (failure becomes an empty disk list), runs `runSessionPickerOverlay`, then switches (`controller.switchSession`) or resumes (`controller.resumeIntoActive` + `refreshSessionMenu`). |
| `controller.openPrompts` | ~line 1302 | Runs `runPromptsOverlay` with `loadUserConfig`; catches `ConfigWriteException` as a warning; a write reports "restart tina to apply"; no write reports `(prompts unchanged)`. |
| `renderImageToPanel` | ~line 1338 | Decodes the image, fits it to the focused panel's interior, and paints through `screen.renderImageAbsolute` onto `contentCoordinator.surfaceOf(panel.conversationId)`. Returns an error string or null. |
| `controller.openImage` | ~line 1404 | Calls the shared renderer and reports errors through the active conversation host with `HostMessageStyle.error`. |
| `pipeline.imageRenderer.coordinate(...)` | ~line 1415 | Registers the same renderer function for the `render_image` agent tool. Teardown resets it with `coordinate(null)`. |
| `_makeSpawnedHost` | ~line 1596 | Builds a detached spawned `TuiConversationHost` (detached `ScrollingTextRegion`, disabled spinner, `active: false`, `primary: false`, role label, `..policy = policy`). |
| `_buildSpawnPanel` | ~line 1631 | Records `tree.parentOf` and `tree.baseLabel`, splits the layout on the first panel (`initialHost.stayAttachedWhenInactive = true`, then `resizeCoordinator.handleResize`), binds through `contentCoordinator.bindSpawned`, then `panelManager.layout()` + `relayContent()`. |
| `_closeRunPanel` / `_openRunPanel` | ~lines 1696–1731 | Opens a read-only run panel synchronously inside the supervisor's `onLaunch` hook (sink installed before the first event), wires stop/close, sets the busy cue, and `run.onFinished = opened.setFinished`. Close clears `onFinished` before teardown. Wired to `handleWorkflowLaunch`. |
| `panelizeRestoredConversation` | ~line 1884 | Wraps a restored conversation in `_buildSpawnPanel` using `restoredLabelOf` and `parentId ?? initialConversationId`. Callers panelize first, then replay history. |
| `pickSpawnedTarget` | ~line 1910 | The shared `/spawn` + `/branch` picker sequence: provider guard, `runSpawnOverlay` (with spawn MRU), then `runToolProfileOverlay`. Returns `(ref, profile)` or null. `pickTarget = spawnTargetPicker ?? pickSpawnedTarget`. |
| `createSideConversation` | ~line 1974 | Builds a `ConversationTarget` from the active session, captures `sourceHost` before awaiting, calls `ConversationOperations.spawn`/`branch`, reports errors through `sourceHost`, keeps a saved conversation if presentation fails, replays branch history after attach, and focuses the new panel. Bound to `controller.openSpawn` / `controller.openBranch`. |

Line numbers will drift as the file is edited. Use the symbols, not the lines.

## Non-negotiable behavior

- The session picker uses the current active session and current live sessions.
  A disk session resumes through the controller, never by rebuilding state.
- A failed disk listing is silent and yields an empty disk list.
- Prompts are restart-only. A successful write must say Tina must restart.
- Image paths resolve against `Directory.current.path`; absolute paths are kept.
- The first spawned panel sets `initialHost.stayAttachedWhenInactive` and then
  runs the canonical resize sequence before the first frame binds.
- The spawn tree stores `parentOf` and `baseLabel` for every spawned
  conversation. Keep the DFS ordering and label restoration.
- A run panel must not steal input focus, and the run sink must be installed
  before the first run event can arrive.
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
  are adjacent to this work but are not part of the first extraction. Do not
  change their ordering or driver-resolution behavior.

## Part 1 — overlay and image handlers

### Goal

Move `openSessionPicker`, `openPrompts`, the shared image renderer, and
`openImage` out of the `create()` closure without changing controller wiring.

### Proposed files

- `lib/tui/coordinator_overlay_handlers.dart`
- `test/tui/coordinator_overlay_handlers_test.dart`

One file is enough: the three handlers share one boundary — prepare input, run
an overlay, report through the current host. Split further only if the module
becomes awkward.

### Dependencies

Define a small explicit dependency object. Do not pass the whole coordinator.
A starting shape:

```dart
final class CoordinatorOverlayDeps {
  final Screen screen;
  final LineEditor editor;
  final SessionManager sessionManager;
  final SessionStore store;
  final AppComposition app;
  final FocusManager focusManager;
  final PanelFrame primaryPanel;
  final Future<BackendSurface?> Function(String conversationId) surfaceOf;
  final void Function() refreshSessionMenu;
}
```

Add nothing that a handler does not use. The image renderer also needs the
`image`, `path`, and `dart:io` imports the coordinator holds today; move them
with the implementation and remove them from `tui_coordinator.dart` only after
analysis passes.

### Wiring seam

A proposed shape (names are not fixed):

```dart
typedef PanelImageRenderer = Future<String?> Function(String path);

PanelImageRenderer wireCoordinatorOverlayHandlers(
  SessionController controller,
  CoordinatorOverlayDeps deps,
) {
  controller.openSessionPicker = () => openSessionPicker(deps);
  controller.openPrompts = () => openPrompts(deps);
  final renderImage = makePanelImageRenderer(deps);
  controller.openImage = (path) async {
    final error = await renderImage(path);
    if (error != null) {
      deps.sessionManager.activeConversation.host.showMessage(
        '$error\n',
        style: HostMessageStyle.error, // the real type name
      );
    }
  };
  return renderImage; // the coordinator keeps pipeline.imageRenderer.coordinate
}
```

Use the real `HostMessageStyle` enum (defined in
`packages/tina_engine/lib/src/host/host_interface.dart`, re-exported through
`package:tina_engine/tina_engine.dart`). Return the renderer function so
the coordinator can hand the identical function to `controller.openImage` and
`pipeline.imageRenderer.coordinate`, and so teardown can still reset it with
`coordinate(null)`. Keep the pipeline coordinate in the coordinator unless the
dependency boundary becomes clearly smaller.

### Tests

Direct unit tests for the new module, not only coordinator integration tests:

- Live and disk entries reach the picker in the same order and shape.
- A failed disk listing yields an empty disk list and does not throw.
- Cancelling the picker leaves the active session unchanged.
- A live pick calls `switchSession` with the selected id.
- A disk pick calls `resumeIntoActive` and refreshes the menu.
- Cancelling prompts leaves the host unchanged.
- A prompts write shows the restart message.
- No prompts write shows `(prompts unchanged)`.
- A prompts write error shows a warning and no success message.
- A missing image returns the existing missing-file message.
- An undecodable image returns the existing decode-error message.
- A panel smaller than 3x3 cells renders nothing.
- A normal image calls `renderImageAbsolute` with the fitted width/height,
  computed position, and the panel's chat surface.
- An image taller than the interior anchors at the top.
- Image errors reach the active conversation host.
- `/image` and the agent tool receive the same renderer function.

Use the existing fake screen, fake session store, and fake environment helpers.
Do not boot the full interactive loop per test.

## Part 2 — panel and side-conversation coordination

### Goal

Move `_makeSpawnedHost`, `_buildSpawnPanel`, `_openRunPanel`/`_closeRunPanel`,
`panelizeRestoredConversation`, `pickSpawnedTarget`, and `createSideConversation`
into a focused module. Keep `ConversationOperations` as the owner of
provider-backed session creation (`spawn`, `branch`,
`ConversationOperationFailure`), and keep `PanelManager` +
`ConversationPanelCoordinator` + `PanelHost`/`RunPanelHost` as the lower-level
owners.

`ConversationOperations` lives in
`packages/tina_app/lib/src/session/conversation_operations.dart` and is exported
from `package:tina_app/tina_app.dart`.

### Proposed files

- `lib/tui/panel_spawn_coordinator.dart`
- `test/tui/panel_spawn_coordinator_test.dart`

### Dependencies

Explicit and small; callbacks over coordinator capture:

```dart
final class PanelSpawnDeps {
  final Screen screen;
  final LineEditor editor;
  final SpawnTree tree;
  final PanelManager panelManager;
  final ConversationPanelCoordinator contentCoordinator;
  final ResizeCoordinator resizeCoordinator;
  final FocusManager focusManager;
  final TuiConversationHost initialHost;
  final AppComposition app;
  final UserConfig Function() loadConfig; // closes over app.environment.env
  final Future<void> Function() reloadConfigProviders;
  final void Function(ConversationCreated created)? sideConversationPresenter;
  final Future<({String ref, ToolProfile profile})?> Function()?
  spawnTargetPicker;
}
```

The module needs the same collaborators the closure captures today:
`policy`, `config.sandboxOffReason`, `app.regexSuggester`, `app.pluginScope`,
`Renderers`, the scheduler registry/pickers for the overlay sequence, the
`SessionStore`, `supervisor` for run panels, and `replayHistory`. Group them
under `deps`; do not widen the type until a handler needs it.

### API sketch

```dart
final class PanelSpawnCoordinator {
  PanelSpawnCoordinator(this.deps);

  TuiConversationHost makeSpawnedHost(String conversationId, {String role});
  PanelFrame buildSpawnPanel({
    required String conversationId,
    required String parentConversationId,
    required String label,
    required TuiConversationHost sinkHost,
  });
  void openRunPanel(WorkflowRun run);   // assigned to handleWorkflowLaunch
  void panelizeRestoredConversation(Conversation conv, {required String? parentId});
  Future<void> createSideConversation({required bool branch});
}
```

The coordinator keeps the wiring: `controller.openSpawn`/`openBranch` delegate
to `createSideConversation`, `handleWorkflowLaunch` to `openRunPanel`, and
`ConversationOperations(... hostFactory: coordinator.makeSpawnedHost ...)` stays
constructed where it is today.

### Tests

- `makeSpawnedHost` returns a detached, inactive host with the given role label
  and the shared policy.
- First `buildSpawnPanel` splits the layout and sets `stayAttachedWhenInactive`;
  a second panel does not split again.
- `buildSpawnPanel` records `parentOf`/`baseLabel`, binds the frame, lays out,
  and relays content.
- `openRunPanel` installs the run sink synchronously, sets the busy cue from
  `run.isRunning`, and assigns `run.onFinished`.
- Closing a run panel clears `WorkflowRun.onFinished` before teardown.
- Stop (`s`) calls `supervisor.stop`; close (`x`) runs the full close path.
- `panelizeRestoredConversation` builds the panel under
  `parentId ?? initialConversationId` with the restored label.
- `createSideConversation` reports creation failure through the captured source
  host, even if the active session changed during the await.
- A saved conversation survives a panel-attach failure, with the existing
  message.
- A conversation created in another session reports there and is not presented.
- A branch replays history only after the panel attaches.
- `/spawn` and `/branch` share one picker; an injected `spawnTargetPicker`
  bypasses the overlays.

## Landing order

1. Commit this plan.
2. Part 1: extract the overlay/image module, add its tests, run the focused
   suites below, commit alone.
3. Part 2: extract the panel/spawn coordinator, add its tests, run the focused
   suites below, commit alone.

Focused suites for both parts:

```sh
dart test test/tui_coordinator_test.dart \
  test/tui/conversation_panel_coordinator_test.dart \
  test/tui/workflow_overlay_handlers_test.dart
```

`dart analyze` must stay clean. Run the full `dart test` before pushing.
