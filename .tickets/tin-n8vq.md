---
id: tin-n8vq
status: closed
deps: []
links: [tin-4m0q, tin-p4wm]
created: 2026-09-25
type: proposal
priority: 2
assignee: Nick Fisher
tags: [docs, permissions, plans, plugins]
---

# Re-document the plan approval boundary now that PR #61 is on main

## Context

The approvals docs pass (tin-4m0q, closed) documented the read-only posture
door as unbuilt and attributed the yolo/unattended fix to the
then-unmerged PR #61. PR #61 has since merged (`0a5ace6`, shipped in
v0.8.30), so the docs were describing a parallel world: the "known gaps"
named behaviour main did not have, and — now that it does — the plan gate
consults `policy.allowAllByDefault` and `host.canAnswerQuestions` through a
helper the *plugin* owns (`PlanTool.resolveApprovalMode`,
plan_plugin.dart:142-149), which is the plugin-side policy re-derivation the
decided boundary rules out. Every file:line cited for #61's shape also moved
when it landed.

## Proposal

- Rewrite docs/features/plan_approval.md against main @ 2118b35 (v0.8.31):
  document the posture read as current behaviour, reframe the gaps as
  structural (door, duplication, answerability dialects, grant provenance),
  re-verify every citation.
- Same corrections in ARCHITECTURE.md and plugin_architecture.md §11
  (including the contrast-table row that still claimed the plan gate is
  governed by "nothing from the permission layer").
- New docs/proposals/plugin_posture_door.md: the forward fix — core mints a
  read-only PlanPosture per conversation, the plugin consumes instead of
  derives, provenance for auto-grants mirrors GrantSource, and a scope-key
  door generalises it for the next consumer.
- File tin-n8vq (this ticket) and rewrite STATUS.md.

## Acceptance

- No doc describes PR #61 as pending or calls `resolveApprovalMode` a gap
  that is "not merged"; main is documented as it is.
- Every behavioural claim verified in code with file+line cited against
  2118b35.
- The proposal's problem section demonstrates the three harms from code,
  with the passing gate tests named as execution proof.
- Documentation only: no code, no tests.
