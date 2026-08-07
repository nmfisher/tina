---
id: tin-80ll
status: closed
deps: [tin-923l, tin-7spm]
links: [tin-923l, tin-7spm]
created: 2026-08-07T14:50:00Z
type: refactor
priority: 2
assignee: Nick Fisher
tags: [workflows, dot, system-prompts, roles, architecture, simplify]
---
# Remove the role concept from DOT workflow nodes

Follow-up to tin-923l / tin-7spm. The proposal in tin-7spm kept roles as the
single source of identity truth and added an additive `instructions` attr. This
ticket goes further: **remove the role concept from nodes entirely.** A codergen
node no longer carries a `role` attribute and no longer resolves an `AgentRole`
for its identity. Instead each node carries its own identity directly:

- `system_prompt` (or `instructions`) — the node's identity prose.
- `llm_model` + `llm_provider` — the node's model, combined into a
  `"provider/model"` reference.

The node run builds the agent from those attrs (plus a fixed default tool set),
not from the role catalog.

## Scope

- `PipelineNode`: drop `role`/`model` getters; add `systemPrompt`, `llmModel`,
  `llmProvider`, and a combined `modelReference`.
- `CodergenBackend.run` / `CodergenHandler`: drop the `role` parameter.
- `SubAgentScheduler.runStandalone`: take a `systemPrompt` (+ `parentReference`/
  `modelReference`) instead of an `AgentRole`; build tools + policy for a node
  (base tool set + `delegate`).
- `TinaCodergenBackend`: resolve the node's system prompt + model; inherit the
  conversation model when the node omits `llm_model`/`llm_provider`.
- Seed workflow: `start -> main -> done`, `main` carrying its own `system_prompt`.
- Validator: drop the `role_unknown` rule and its `knownRoles` parameter.
- Workflow editor node-attr form + DOT writer: show/write the new attrs.

## Open questions (answered)

- **Delegate catalog.** Unchanged. Sub-agents still get their identity from the
  `AgentRole` catalog via the `delegate` tool (`research`, `implementer`,
  `verifier`, …). Roles are removed only from *nodes*; a node agent reaches the
  catalog through `delegate`. Two clean paths: node agents built from node attrs,
  sub-agents built from the catalog.
- **Seed workflow.** A single `main` node with its own `system_prompt`, edge
  `start -> main -> done`. `main`'s prompt tells it to plan and delegate to
  specialist sub-agents (research/implementer/verifier/tester) via `delegate`.
- **Model stylesheet.** Not wanted for nodes (keep it simple). A node spells out
  `llm_model` + `llm_provider` concretely, or omits both to inherit the
  conversation's model. No tier indirection for nodes (the tier map stays for
  sub-agent roles).
- **Editor.** The node-attr form shows `system_prompt`, `llm_model`,
  `llm_provider` instead of `role`/`model`. A node's sub-line in the graph
  viewer shows its model when set.

## Acceptance Criteria

Nodes no longer use `role`/`model`. A codergen node runs an agent built from its
`system_prompt` + `llm_model`/`llm_provider` (inheriting the conversation model
when omitted) with the default tool set + `delegate`. The seed workflow is
`start -> main -> done`. Sub-agents still resolve through the catalog. The
editor writes the new attrs. Tests pass.

## Result

Implemented in PR #2 (commit `9341944`). Nodes carry `system_prompt` (alias
`instructions`), `llm_model`, `llm_provider`; the node run builds the agent
from those via `runStandalone(systemPrompt: …)` + a new `resolveIdentityPrompt`
wrapper, with the conversation model inherited when the node omits its model.
`role`/`model` getters, the `role` parameter on `CodergenBackend.run`, and the
validator's `role_unknown`/`knownRoles` plumbing are removed. The seed is
`start -> main -> done`. Sub-agents are unchanged (still the role catalog via
`delegate`). A failing test (`graph_node_identity_test.dart`) was written
first; all tests touched by the change pass. Pre-existing, unrelated failures
(search_tool, process_tree, tina_index graph_test, one session_controller
timing test) were confirmed to also fail on the base code. Status
`started -> closed`.
