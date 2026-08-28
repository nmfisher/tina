---
id: tin-80ll
status: done
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

## Closure (2026-08-28, closed as landed)

All four acceptance criteria are met on main; the work landed upstream in
the attractor-spec series:

- `beb9a0a` per-node model attribute; `9341944` "tin-80ll — remove the
  role concept from DOT nodes"; `d7be7cd` delegate catalog removed.
- No `role`/`AgentRole` in the DOT path — only wire-format message roles
  remain (llm/*.dart). `agent_pipeline.dart:57`: "A sub-agent no longer
  carries its own tool set (there are no roles)."
- Nodes carry identity + model: `system_prompt`, optional
  `llm_model`/`llm_provider` (default_workflow.dart:147-149,
  tina_codergen_backend.dart:6-9, :72), falling back to the conversation
  model.
- Default workflow is role-free (kDefaultWorkflowDotSource: intake,
  plan, double review, fan-out, executors — each with its own
  system_prompt).
- Delegates: catalog removed; sub-agents inherit the node's identity
  plus the delegation's task and an optional tool profile
  (read-only/full) and model (delegate tool; fallback identity at
  tina_codergen_backend.dart:110-113).
- Model-stylesheet equivalent = the per-node llm_model/llm_provider
  attrs; the /workflow editor round-trips DOT text, so the attrs are
  directly editable (help at pipeline_commands.dart:87).

Tests: test/pipeline 20/20, packages/tina_engine test/agent 189/189,
CI 4/4 green on main tip 8cd544e.
