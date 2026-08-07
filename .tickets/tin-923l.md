---
id: tin-923l
status: closed
deps: []
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

## Proposal — single source of truth for agent identity, prompts, and tools

Two layers, one identity each, no overlap:

1. **The `AgentRole` catalog** (`packages/tina_engine/lib/src/agent/agent_pipeline.dart`)
   is the single source of truth for each agent's *system prompt*
   (`promptIdentity`), *tools*, *model tier*, and *delegation capability*. Tools
   are symbolic references (compile-checked), so they cannot live in a DOT file —
   the catalog is necessarily the source. **One role name = one identity.**
2. **DOT workflow files** (`~/.tina/workflows/*.dot`, seeded from
   `kDefaultWorkflowDotSource`) are the source of truth for the *per-turn task*
   (a node's `prompt`, expanded with `$input`/`$history`) and *graph routing*
   (which role runs at each node, `VERDICT:` edge selection). A node contributes
   **only its task**; its identity/tools/model come from its `role` attribute
   resolving the catalog.

### What the conflict was, and the fix

The default chat workflow ran `orchestrator` nodes (plan/execute) whose
`promptIdentity` is a repo-overview "launch 1–3 scout sub-agents" flow — so the
node's task prompt fought the role's system prompt, and scouts appeared by
surprise. A node with no `role` also defaulted to `orchestrator`, so the same
confusing identity ran whenever a role was omitted.

The fix keeps the catalog authoritative and makes **`main` the default node
role** and **the seeded default workflow a single `main` node**. `main` is one
delegating agent (no file tools, `canDelegate`) that delegates repository
exploration to `research` sub-agents — exactly the no-workflow interactive
agent, now also the DOT-routed default. `orchestrator`/`scout` remain available
(used by the sidecar-summaries fleet and as delegatable specialists) but are no
longer the default, so they never run by surprise. No identity prose is
duplicated across layers.

### Mechanism (minimal code change)

- `AgentPipeline.resolveRole(name)`: resolves `main` (and any sub-role) for a
  node, while `role()`/`delegateTargets` still exclude `main` — it is the entry,
  never a delegation target. `resolvableRoleNames` is the single set
  `validate(knownRoles:)` consumes.
- `TinaCodergenBackend.defaultRole` → `'main'`; nodes resolve via
  `pipeline.resolveRole`.
- `_mainIdentity` rewritten to describe direct delegation to
  `research`/`implementer`/`verifier`/`tester` via `delegate`, dropping the stale
  "communicate with a single orchestrator agent" indirection.
- The default workflow seed becomes `start → main → done`, the `main` node
  delegating repo exploration to `research`.
- Because `main` carries no model tier (it inherits the conversation's model),
  the live conversation model is threaded into the pipeline run as the
  standalone node's parent reference — so the default chat agent runs on the
  model you are chatting with, not a fixed tier.

