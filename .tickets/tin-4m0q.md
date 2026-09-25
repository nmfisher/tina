---
id: tin-4m0q
status: closed
deps: []
links: [tin-p4wm, tin-y9k2]
created: 2026-09-25
type: proposal
priority: 2
assignee: Nick Fisher
tags: [docs, permissions, plans, plugins]
---

# Document the two approval mechanisms and the core/plugin boundary

## Context

ARCHITECTURE.md never mentioned the plan system; the plugin architecture
proposal said nothing about what plugins may do with approvals;
permission_rules.md covered only the tool side. A reader could not learn
that there are two approval mechanisms, what separates them, or where the
boundary sits. Decision to record: plan approval stays a plugin; core owns
the permission decision; a plugin must not re-derive policy.

## Proposal

- New docs/features/plan_approval.md mirroring permission_rules.md: the
  plan mechanism, contrasted with tool approval at every step.
- ARCHITECTURE.md: a subsection under the permissions section introducing
  the second mechanism, the LocalControlTool short-circuit that makes the
  permission layer structurally unable to govern it, and the boundary.
- plugin_architecture.md §11: what plugins may and may not do about
  approvals, with plan approval as the worked example.
- Cross-references both ways, including plan_overlay.md (presentation doc,
  referenced not duplicated) and permission_rules.md.

## Acceptance

- Every behavioural claim verified in code with file+line cited.
- The intended read-only door documented as a gap, never as behaviour.
- The "not purely a plugin" nuance for the plan tool stated.
- Documentation only: no code, no tests.
