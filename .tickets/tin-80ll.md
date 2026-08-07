---
id: tin-80ll
status: open
deps: []
links: []
created: 2026-08-07T14:26:36Z
type: feature
priority: 2
assignee: Nick Fisher
tags: [workflows, roles, system-prompts, codergen, refactor]
---
# Remove the role concept from workflow nodes; nodes carry their own system prompt and model config

Design decision from the attractor-spec review: the original spec has no roles — a codergen node has a task prompt, model/provider config, and the backend supplies identity. Align tina with that: remove the role attribute and the AgentRole catalog from the DOT workflow path. Each codergen node instead carries its own system prompt or instruction attribute plus llm_model and llm_provider attributes, and the node run builds the agent from those. Follow-on questions the implementation must answer: what happens to the delegate catalog (research, implementer, verifier, scout, etc.) — sub-agents still need identities; how the seeded default workflow changes (a main node with its own system prompt); whether a model-stylesheet equivalent is wanted; and how the /workflow editor shows the new attrs. Supersedes the role-based direction of tin-923l PR 1; builds on the tin-7spm proposal. Keep it simple.

## Acceptance Criteria

DOT workflow nodes no longer use role or AgentRole for identity. Each codergen node can set its own system prompt, llm_model, and llm_provider. The default workflow works without roles. Delegate targets for sub-agents still exist with sensible prompts. Tests pass.

