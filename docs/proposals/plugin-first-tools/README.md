# Plugin-first tools — phase specifications

Status: PT0 implemented; PT1/PT2 proposed.
Date: 2026-09-23.
Parent context: `docs/proposals/plugin_architecture.md`, `docs/features/renderers.md`.

These specifications split the "everything pluggable lives in the plugin
scope" migration into independently landable phases. Each phase lands green
on its own; nothing is feature-flagged. Proposed type names and signatures
are illustrative, not existing APIs — later phases may correct earlier ones
during implementation (SP1 did).

## Shared context

The plugin seam already carries the base tool catalog:
`workspaceToolPlugins` (`packages/tina_engine/lib/src/tools/workspace_tool_plugins.dart`)
mounts one descriptor per tool (`tina.tool.read` … `tina.tool.git`, plus
`web_search`), and `toolRegistryFromScope` assembles the registry. The chat
renderer, git/intent input classifiers, provider decorators, and the session
store travel the same way.

What is still hand-wired is the **conversation-scoped surface**: `buildAgent`
(`packages/tina_app/lib/src/composition/agent_composition.dart`) imperatively
adds `launch_workflow`/`stop_workflow` (now unmounted unconditionally —
spawning_constraints Change 1; previously behind `config.enableWorkflow`), the
seven region tools, `ask_user`, `render_image`, `explore_project`, and the
delegate/channel wrapper — plus a hardcoded allow-table in `mainPolicy`
naming those same tools. The plugin runtime activates once per process,
before any conversation exists, so these tools cannot be plain
`PluginDescriptor`s: their constructors need per-conversation values
(`conversationId`, `sink`, `parentReference`, `originConversationId`).

The target shape: **the app is a set of primitives with a default set of
plugins.** The launcher lists plugins; plugins decide for themselves what to
contribute; `buildAgent` becomes a collector, not an assembly line.

## Specifications

| ID | Specification | Principal result | Prerequisites |
| --- | --- | --- | --- |
| PT0 | [Launcher-conditional plugins + explore_project](01-launcher-plugins-and-explore.md) | Every tool reachable from a process scope is a scope contribution | None |
| PT1 | [AgentToolFactory contribution kind](02-agent-tool-factories.md) | The conversation-scoped surface (workflow, regions, ask_user, render, delegate) are plugins; `buildAgent` collects | PT0 |
| PT2 | [Permission defaults ride with tools](03-permission-rideshare.md) | The interactive-main allow-table lives next to the tools it names | PT1 |
| — | TUI panel provider (see README §Deferred) | — | — |

## Invariant every phase must preserve

For the default config, the **tool name set and the resolved permission
decision table are byte-identical** to the pre-refactor behavior, for each of
the four build shapes:

1. headless worker (`withSubAgents: false`),
2. interactive main (`withSubAgents: true`),
3. orchestrator turns (fail-closed guard),
4. delegated sub-agents.

Pin these as goldens in PT0 (against today's output) and keep them green
through PT1/PT2. If a phase changes the goldens, that is a spec violation,
not a follow-up.

## Deferred

**TUI panel provider.** A `TuiPanelProvider` contribution for panels,
overlays, and menus is conceivable, but those surfaces are stateful and
coupled to the coordinator's key routing; the *valuable* TUI seams (renderers,
conversation style, prompt, approval cards) are already pluggable. Do not
schedule. Revisit only if a concrete second panel implementation appears.

## Stays kernel (non-goals)

The plugin runtime itself, config parsing, the provider registry, the
scheduler/agent loop, and permission *enforcement* (the policy engine and
asker). Plugins may contribute policy inputs (rules, per-tool decisions);
the enforcement mechanism is not swappable.
