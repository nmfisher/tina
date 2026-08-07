---
id: tin-7spm
status: closed
deps: []
links: [tin-923l]
created: 2026-08-07T11:20:19Z
type: chore
priority: 2
assignee: Nick Fisher
tags: [workflows, dot, system-prompts, handoff, design, proposal]
---
# Explore node handoff design for workflows — propose (no implementation)

Follow-up to tin-923l. Design question: we want a system prompt PER NODE in DOT workflows, and the open question is how one node hands off to another. If a main node must hand off to a reviewer, it can either decide the handoff itself (agent-directed, e.g. via the delegate tool) or follow hard-coded prompts/edges (engine-enforced graph routing, e.g. current VERDICT edge-label routing). Explore: per-node system prompts (where they live — node attrs vs role resolution), hard-coded vs system-prompt-directed handoff vs a hybrid, and what the main→reviewer example implies for routing, determinism, auditability, and flexibility. Deliver a concrete proposal with options, trade-offs, and a recommendation. PLAN ONLY: do not implement. Do not restrict what changes you may consider; just produce the proposal.

## Acceptance Criteria

A written proposal covers per-node system prompts and node handoff (hard-coded edges vs system-prompt-directed delegation vs hybrid), with options, trade-offs, and a recommendation. No implementation changes are made.

## Result

Proposal delivered at `docs/proposals/node_handoff_design.md`.

- **Q1 (per-node system prompts):** roles stay the single source of identity truth (Option A, per PR #1/tin-923l); add an optional *additive* node `instructions` attribute (Option C) for per-node framing; reject wholesale `system_prompt` replacement (Option B).
- **Q2 (node handoff):** hybrid (C) — engine-enforced graph edges for guaranteed structure, `delegate` for dynamic intra-node fan-out, and the existing `Outcome.suggestedNextIds` (engine edge-selection Step 3) as the bounded bridge for agent-chosen next nodes. Keep PR #1's single-`main` delegation as the default chat path; reserve multi-node graphs for workflows needing determinism/audit.

No code or tests changed. Plan only.

## Follow-up (2026-08-07)

Added §7 "Follow-up: nodes vs agents (clarification)" to `docs/proposals/node_handoff_design.md`,
answering: (1) a node is a fresh one-shot `Agent` built per turn from the node's `role`+`prompt` by
the scheduler — not a long-lived agent, and not the same agent re-prompted; (2) each node has its own
turn loop and a fresh empty message history, but all nodes in a run share one `Context` store, with
data passed forward as preamble text (no shared LLM memory); (3) a graph-edge handoff is the same
engine building a fresh one-shot agent with a new role, while a `delegate` handoff spawns a real
nested sub-agent instance inside the parent turn. Status stays `closed`: this is a clarification of
the delivered proposal, not new implementation.

