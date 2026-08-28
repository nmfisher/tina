---
id: tin-923l
status: done
deps: []
links: [tin-80ll]
links: []
created: 2026-08-07T10:52:21Z
type: chore
priority: 2
assignee: Nick Fisher
tags: [workflows, dot, prompts, roles, architecture, simplify]
---
# Unify workflow prompts: DOT files vs hardcoded AgentRole identities (propose simple design)

Current situation: normal chat turns route through ~/.tina/workflows/default.dot, seeded from kDefaultWorkflowDotSource in lib/pipeline/default_workflow.dart — a plan→review→execute pipeline with VERDICT routing. DOT nodes carry task prompts (expanded with $input/$history); they do NOT carry system prompts or tools. Each node's role attr resolves a hardcoded AgentRole in packages/tina_engine/lib/src/agent/agent_pipeline.dart (main, research, implementer, verifier, tester, orchestrator, scout, summarizer, qa) which supplies the system prompt (promptIdentity), tools, and model tier. A node with no role attr defaults to 'orchestrator' — whose identity is the repo-overview agent (reviews the repo, delegates scouts), confusing when used as the chat default. The delegate catalog is also hardcoded. Observed symptoms: the main agent label shows the model name (diffusiongemma), scout sub-agents appear when the repo-overview flow runs, and it is unclear which prompts apply where. Ask: propose ONE simple unifying solution — a single source of truth for agent identity, prompts, and tools; make the default experience 'one main agent that delegates repository exploration to research sub-agents'; remove the duplication/conflict between DOT node prompts and hardcoded role identities; keep it simple; implement the minimal change with tests and update the seed + docs if needed.

## Acceptance Criteria

A clear proposal documents the single source of truth. The default chat experience is one main agent (role main, no file tools, canDelegate) with research sub-agents. No conflicting/duplicated prompt sources remain. Minimal code change + tests pass.

Note (2026-08-18): tin-80ll records the attractor-spec review decision
that supersedes this ticket's role-based direction (nodes carry their own
system prompt + model config; no AgentRole). Pick them up together — 80ll
is the decided path; this ticket's remaining value is the
single-source-of-truth unification ask.

## Closure (2026-08-28, closed as realized by tin-80ll)

This ticket's superseded role-based direction is moot, and its remaining
ask — a single source of truth for identity/prompts/tools — is realized
by the tin-80ll design:

- One source: the DOT node's own attributes (`system_prompt` identity,
  `prompt` task, `llm_model`/`llm_provider` model). No hardcoded role
  identities exist to conflict with node prompts (AgentRole removed,
  `9341944`; delegate catalog removed, `d7be7cd`).
- Default chat experience: the manager loop (docs/features/manager_loop.md,
  default_workflow.md) — one main agent OUTSIDE the workflow; the default
  graph launches on demand via `launch_workflow`, its intake/executor
  nodes delegating read-only/full sub-agents. The AC's "role main" wording
  was superseded by this decided shape (the ticket's 2026-08-18 note
  already deferred to tin-80ll as the decided path).
- No duplicated/conflicting prompt sources remain: node task prompts and
  node system prompts are the same attribute set a user edits with
  /workflow edit.
