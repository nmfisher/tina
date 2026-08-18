---
id: tin-923l
status: open
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

