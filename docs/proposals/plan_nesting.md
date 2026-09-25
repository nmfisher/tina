# Proposal: expandable sections + tree traversal in the plan overlay

Status: proposal (not implemented). A handoff brief for implementation — an
agent (or human) should be able to execute it without further design input.
Line anchors were true when written; grep them, don't trust them.

## Goal

The plan overlay (the Ctrl+P panel, `lib/tui/plan_overlay.dart`) renders a
FLAT list: `Plan.items` are text+state rows and the selection is an index into
that flat list (`packages/tina_app/lib/src/plans/plan_store.dart:16-21`). Add
optional nested sub-items: a parent row can expand/collapse to reveal its
children, ↑/↓ traversal walks the visible tree, and every plan consumer
handles nesting: the `update_plan` tool schema, the `/plan` commands,
`PlanMiddleware`'s per-turn context injection, and the status-strip summary.

## Current shape (verify each anchor before editing — line numbers drift)

- Data: `packages/tina_app/lib/src/plans/plan_store.dart` — `Plan` (:16),
  flat items, `PlanApproval` (:11), content updates reset approval
  (:153-157). Plans persist as opaque blobs on `ConversationMeta.plan`
  (`updateConversationTrackers`) — load must stay LENIENT (precedent:
  `Goal.fromJson`).
- Renderer: `lib/tui/plan_overlay.dart` — pure `renderPlanOverlayLines`
  (:58-147, byte-identical goldens in `test/tui/plan_overlay_test.dart`),
  `PlanOverlayUi` view-model (:16-40: `collapsed` flag, selection index),
  height budget `planOverlayContentHeight` (:199), `handleEvent` (:321-373):
  ↑/↓ move selection (:434-441), space toggles pending↔done (:394-416),
  `a` / Ctrl+Enter approve, `r` reject, Ctrl+P global collapse/expand (:468),
  auto-degrade when the box doesn't fit (:492-496). Plain Enter currently
  falls through — verify, then claim it (see keys below).
- Writers/consumers: `update_plan` tool + `PlanMiddleware`
  (`packages/tina_app/lib/src/plans/plan_plugin.dart` — tool schema,
  `requestApproval` :155, context injection :21-47), `/plan` commands
  (:263-265 area), `PlanStatusSource`/`PlanSummary` (strip counts).

## Settled decisions (do not re-litigate)

- ONE level of nesting: children have no children.
- Children are full items: text + pending/done state, space-togglable, counted
  in progress (parent shows "done when all children done" is NOT required v1 —
  a parent can be ticked independently).
- Collapse state is EPHEMERAL view-model state on `PlanOverlayUi` (same as
  selection) — never persisted in the plan blob.
- Keys: ↑/↓ walk the flattened VISIBLE rows (children sit between their parent
  and the next sibling). space = toggle state (unchanged). Enter on a parent
  WITH children toggles subtree expand/collapse (consumed); Enter elsewhere
  stays fall-through. ←/→ MUST keep passing through — Ctrl+G focus cycling
  depends on it. Do not claim them.
- Old blobs without a children field load unchanged (absent = empty list).
- Approval reset (content change ⇒ approval none) extends to any child's
  content.
- `update_plan` schema: items gain optional `children: [{text, state}]`;
  `PlanMiddleware` renders children indented under the parent; strip counts
  include children.
- Renderer: children indented 2 spaces, ▸/▾ glyph on parents with children,
  collapsed parent shows a dim `(+2 subtasks)` marker; height budget counts
  visible rows only.
- `/plan` text commands stay top-level-indexed; dotted addressing
  (`/plan done 2.1`) is a nice-to-have — skip if it complicates parsing.

## Verify (gate before done)

`dart analyze`; extended `plan_overlay_test` goldens (nested expanded,
collapsed, selection walking past subtrees); `plan_store` round-trip with
children + old-blob lenient load; `plan_plugin` schema/middleware tests;
`packages/tina_app/test/plans/plan_approval_gate_test.dart` pins approval
semantics and must stay green.

## Warnings

- `renderPlanOverlayLines` must stay PURE (byte-identical goldens) — extend
  its inputs, never reach into host state.
- Keep the fall-through rule: unhandled keys reach the editor so typing keeps
  flowing while the overlay is focused. Only ↑/↓/space/Enter-on-parent/a/r/
  Ctrl+Enter are consumed.
- Selection semantics: index-over-visible-rows recomputed per render (or item
  ids) — pick one, document it at the field, fix the clamps in `_setSelected`.
- If the workspace-questions overlay (`classifier_review_overlay.dart`,
  separate proposal) has landed, it nests identically — share the
  indent/glyph helper rather than diverging.
- Commit style: `feat(tui)` / `feat(plans)` — match `git log --oneline -15`.
