---
id: tin-m4qk
status: closed
deps: []
links: [tin-80ll]
created: 2026-08-08T05:40:00Z
type: chore
priority: 2
assignee: Nick Fisher
tags: [workflows, manager-loop, system-prompts, consistency, refactor]
---
# Align the default main-agent system prompt with the manager-loop structure

The manager-loop change (commit ac47a09, docs/features/manager_loop.md) moved the main/chat agent outside the workflow: it now runs its own turns and launches DOT workflows as background child runs (/workflow run, /workflow stop, report-back). The default system instructions were not updated to match. Findings from a consistency review of the recent commits:

1. The chat agent identity _mainIdentity (packages/tina_engine/lib/src/agent/agent_pipeline.dart:231) still describes the old model — "do the work directly or delegate ... with the `delegate` tool." It never mentions launching/monitoring/stopping a workflow. The model cannot discover the manager-loop capability from its own instructions, so it will never spontaneously route large jobs to a structured graph. (DONE in this ticket: prompt rewritten to describe all three modes — work directly, delegate, launch workflow.)

2. The prompt contradicts the tool registry. Interactive main is built with NO file tools (lib/composition/agent_composition.dart:95 — only RenderTool + delegate + channels), yet the old prompt said "do the work directly / Read each file before editing it." The comment at lib/composition/agent_composition.dart:38 referenced a phrase ("you do not read, write or edit files directly") that no longer existed in the prompt. (DONE in this ticket: prompt phrased conditionally on "the tools available to you" so it is accurate in both interactive (no file tools) and headless --prompt (full tools) modes; comment updated.)

3. Two overloaded "main" identities describe opposite jobs: the chat/manager agent (_mainIdentity, "do the work directly") vs the default.dot main node (lib/pipeline/default_workflow.dart:179, "Do not write code ... hand ... to the plan node"). Conceptually different agents now (supervisor vs workflow entry node) but both labelled "Main"/"main", with nothing explaining the relationship. (DONE in this ticket: renamed the default.dot entry node main → intake across the seed DOT, its flow comments, its system_prompt (dropped the inaccurate "you talk with the user" / "you are the main coding agent" lines), the plan node's prompt ("the intake summary"), test/default_workflow_test.dart, and docs/features/default_workflow.md + agent_pipeline.md. The historical proposal docs/proposals/node_handoff_design.md is left as the design record.)

4. Stale role/AgentRole commentary after tin-80ll removed the role concept: packages/tina_engine/lib/src/persistence/session_store.dart:188,213,238 ("so [targetName] (the role name) fully determines its tool set on resume" — that resolution model was removed) and lib/tui/prompts_overlay.dart:46 ("built around AgentRole"). (DONE in this ticket: comments reworded to describe the persisted-policy + label model.)

Note: tin-80ll is still status: open; its acceptance criterion "Delegate targets for sub-agents still exist with sensible prompts" overlaps with items 1–2.

## Acceptance Criteria

The default main-agent system prompt describes the manager-loop workflow-launch capability alongside direct work and delegation. The prompt no longer instructs the interactive agent to use file tools it does not have. Stale role/AgentRole comments are corrected. Tests pass. Items 3 and 4 either fixed or split into their own tickets.

## Close note

Closed 2026-08-16: all four items verified done in code — manager-loop prompt in _mainIdentity (launch_workflow + delegate + conditional file-tools phrasing, agent_pipeline.dart), no stale "you do not read, write or edit files directly" comment (agent_composition.dart), default.dot entry node renamed intake (default_workflow.dart), no AgentRole references left in session_store.dart / prompts_overlay.dart. Root suite +538 and tina_engine suite green. Ticket body already marked items DONE; closing.
