# Proposal: Plan overlay panel

Status: implemented (stages 1–4: model/approval, Ctrl+P toggle, overlay panel, config + wiring)
Tickets: —

This proposal covers the *presentation* of the plan — the overlay panel, its
keys, and its approval badge. The approval *mechanism* itself (the state
machine, who may move it, and how it differs from tool approval) is
documented in [Plan approval](../features/plan_approval.md).

## Problem

The plan tracker exists end to end — `PlanStore` (`packages/tina_app/lib/src/plans/plan_store.dart`),
the `update_plan` tool, request middleware, the strip line (`plan: fix regex · 2/5 done`)
and the `/plan` command — but the only always-visible surface is one status-strip
line. To see the actual items a user runs `/plan` and reads scrollback. There is
no at-a-glance view of:

- the full item list with per-item state,
- overall progress (2/5 done) beyond the strip summary,
- whether the plan is approved,
- structure (sections), or room to add it.

## Goal

When the focused conversation has an active plan, render it as a floating
overlay column beside the chat. It updates live while the agent works,
distinguishes pending / in-progress / done at a glance, carries an approval
badge, and can be collapsed — without stealing the keyboard from the input
line.

Non-goals: editing plan *content* in the overlay beyond state toggles; a
second plan model; modal blocking of chat.

## Current shape (what we build on)

| Piece | Where | Note |
|---|---|---|
| `Plan`, `PlanState`, `PlanStore` | tina_app `plan_store.dart` | immutable values, wholesale `update`, broadcast `changes`, caps (64 items / 240 chars) |
| `PlanStatusSource` / `PlanSummary` | tina_app `plan_plugin.dart` | strip view-model; declines empty plans |
| `PlanStatusRenderer` | `lib/tui/plan_status_renderer.dart` | pure `Renderer<PlanSummary>` |
| `InputStatus` | `lib/tui/input_status.dart` | discovers sources, reads per focused conversation id |
| `OverlayRegion` | tina_console `region.dart` | floating surface, `update(bounds, lines)`, falls back to standard plane |
| Key precedent | `onMaximizeToggle` (Ctrl+O), `onRawView`, `onBlockCursor` | app hooks at one dispatch rank: after modal layer, before focus ring |

Everything the overlay needs already exists except the overlay itself, one
control code, and an approval field on the model.

## Design

### 1. Model: approval state (tina_app)

`Plan` gains an approval dimension; the store owns transitions:

```dart
enum PlanApproval { none, requested, approved, rejected }

class Plan {
  final List<({String text, PlanState state})> items;
  final PlanApproval approval;
  ...
}
```

- `PlanStore.update` resets `approval` to `none` whenever item *content*
  changes (order/text/additions) but preserves it when only states flip —
  an edited plan must be re-approved, progress updates must not.
- New methods `requestApproval(id)`, `approve(id)`, `reject(id)` — each a
  mutation on the same `_plans` map, firing the same `_changes` broadcast, so
  the strip and the overlay update with zero new plumbing.
- `PlanSummary` carries `approval` so the existing strip renderer can show
  `plan: fix regex · 2/5 done · needs approval`.

Who calls `requestApproval` is phase-later (see §6); the state machine and
surfaces land first.

### 2. View-model + renderer (pure, testable)

`lib/tui/plan_overlay.dart`:

```dart
class PlanOverlayState {           // UI-only state, lives in the overlay object
  bool collapsed;                  // header-only strip vs full list
  int  cursor;                     // highlighted item, for keyboard toggles
}

List<String> renderPlanOverlay({
  required Plan plan,              // or null → empty list (overlay hidden)
  required PlanOverlayState ui,
  required int width, required int height,
  required Theme theme,
});
```

Rendered shape (docked right, `width ≈ min(42, w/3)`):

```
┌ plan · 2/5 done ─────────────┐
│ ✓ read parser tests          │   done      (dim + ✓)
│ ✓ add failing case           │   done
│ ▸ fix regex backtracking     │   in progress (accent + spinner frame)
│   · update docs              │   pending   (dim ·)
│   · release                  │   pending
├──────────────────────────────┤
│ ● approval requested — ⏎ approve · esc close │
└──────────────────────────────┘
```

- Icons come from `PlanState`; colors from `Theme` SGR codes only (`dim`,
  accent, warning) — same discipline as the strip renderer.
- `collapsed: true` renders header + active item + counts only (2–3 rows);
  the overlay shrinks its bounds to the content height.
- All box drawing reuses `boxLines` (the panel-maximize helper).

### 3. Overlay host (tina, non-modal)

`PlanOverlay` in the same file owns the `OverlayRegion` + lifecycle:

- Constructed in `tui_coordinator.dart` next to `panelManager`, holding
  `screen`, the `PlanStore` (same instance `planUiPlugin` was built with),
  and a `conversationId()` callback (the same one `InputStatus` uses, so the
  overlay always shows the *focused* conversation's plan).
- Subscribes `store.changes`: on each event, re-reads the focused
  conversation's plan. Empty plan → `hide()`; non-empty → `update(...)`.
  This gives live per-item animation "for free" while the agent works.
- **Not modal**: never `modalTakeFocus`. Chat input stays live; the overlay
  is a passive mirror like the strip, until the user gives it keys (§4).
- Mode: `auto` (show whenever a plan exists — default), `manual`
  (Ctrl+P only), `off`. One config knob in `lib/config.dart`; `auto` may
  degrade to `manual` on narrow terminals (< ~100 cols) where a docked
  column crowds the chat.

### 4. Keys

- **Ctrl+P** (`ControlCode.ctrlP`, byte 0x10 — not a tty signal in raw mode,
  no readline collision; needs mapping in `input_parser.dart` and
  `notcurses_input_backend.dart` like ctrlO) → new editor hook
  `onPlanToggle` at the established rank (after modal layer, before focus
  ring). Returns true when it consumed the key: toggles overlay visible⇄hidden.
- While visible, **Ctrl+P again** (or `tab`) gives the overlay the keyboard:
  arrows move the item cursor, `enter`/`space` cycle that item's state
  (exactly the mutation `/plan done <n>` already performs — the overlay
  writes through `PlanStore.update`, so validation and broadcasts are
  shared), `e` toggles collapsed, `esc` returns focus to chat (overlay stays
  visible) or hides it when pressed twice. Implement with
  `editor.captureKeyReader()` held only while the overlay has keys —
  the same loop shape as `runToolOutputViewer`, but the reader is
  acquired/released on focus entry/exit rather than for the overlay's
  lifetime.
- Manual state edits do **not** touch `approval` (only states flipped, see §1).

### 5. Composition wiring

`planUiPlugin` already registers the store service and strip pieces; the
overlay is *app* UI (needs `Screen`), so it is constructed in the
coordinator, not as a scope contribution — consistent with
`runMaximizedPanelOverlay`. The composition root passes the same `PlanStore`
instance it gave `planUiPlugin` into the coordinator's constructor
environment.

### 6. Approval flow (later phase, model ready)

- Agent side: a `request_plan_approval` local-control tool (same
  `LocalControlTool` shortcut as `update_plan`) that flips
  `none → requested` and returns "waiting for approval".
- Host side: the existing approval-card path listens for `requested` and
  surfaces approve/reject (or it is driven purely from the overlay /
  `/plan approve|reject` commands, which the store methods already support).
- `PlanMiddleware` includes the approval state in the `<current-plan>`
  section so the model knows to proceed or wait.

## Files touched (phase 1+2)

| Change | File |
|---|---|
| `PlanApproval`, store transitions, summary field | `packages/tina_app/lib/src/plans/plan_store.dart`, `plan_plugin.dart` |
| strip renderer shows approval | `lib/tui/plan_status_renderer.dart` |
| `ctrlP` code + parser + notcurses backend | `packages/tina_console/lib/src/input_event.dart`, `input_parser.dart`, `backend/notcurses_input_backend.dart` |
| `onPlanToggle` hook | `packages/tina_console/lib/src/line_editor.dart` |
| overlay render + host | `lib/tui/plan_overlay.dart` (new) |
| wiring, lifecycle, focus-follow | `lib/tui_coordinator.dart` |
| `plan_overlay` mode knob | `lib/config.dart` |
| tests (pure render + fake-screen host, store transitions) | `test/tui/plan_overlay_test.dart`, `packages/tina_app/test/plans/…` |

## Test plan

- Store: approval resets on content change, preserved on state-only change;
  transitions fire `changes`.
- Renderer: golden strings for each state/collapsed/approval combination at
  fixed width (pure function, no screen).
- Host: fake-screen test like `panel_maximize_test.dart` — canned
  `InputEvent`s drive toggle, focus, state cycle, esc-esc; assert overlay
  bounds/lines and that hide repaints nothing it shouldn't.
- Architecture suite stays green (new tina file → `policy.json` unchanged;
  tina_app additions carry no console imports).

## Alternatives considered

- **Modal centered popup** (Ctrl+O style): simplest input handling, but
  blocks chat while a turn streams — the main use case is watching the plan
  update *while* the agent works.
- **A real sidebar panel** in `PanelManager`: gets focus-ring integration
  for free, but plans are per-conversation state, not a panel; the overlay
  follows the focused conversation without touching panel geometry.
- **Render plan lines into the transcript**: survives scrollback but not
  live, and duplicates what `/plan` already does.
