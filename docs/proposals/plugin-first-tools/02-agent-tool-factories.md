# PT1 — AgentToolFactory contribution kind

Status: proposed.
Prerequisites: PT0.
Index: [README.md](README.md).

## Problem

The conversation-scoped tools cannot be plain `PluginDescriptor`s because
their constructors need per-conversation values: `LaunchWorkflowTool` takes
`supervisor`, `conversationId`, `sink`; the region query/broadcast tools take
`scheduler`, `parentReference`, `originConversationId`; `render_image` takes
the pipeline's image renderer; delegate/channel take an `AgentToolContext`.
Today `buildAgent` constructs all of these imperatively, which is the last
assembly-line code in the composition and the reason "add a custom agent
tool" is a core edit rather than a plugin.

## Design

One new contribution kind, next to `Tool` and `Renderer<T>`:

```dart
/// Builds conversation-scoped tool contributions for one agent build.
/// Return null to contribute nothing for this build (feature off,
/// dependencies absent) — an empty list contributes nothing too.
abstract class AgentToolFactory {
  List<Tool>? build(AgentToolContext ctx);
}
```

`AgentToolContext` already exists (`scheduler`, `pipeline`,
`parentReference`, `parentPolicy`, `originConversationId`, `depth`) and is
built in every `buildAgent` path today. Two additions it needs:

- `sink` (the host) — `LaunchWorkflowTool` wants it;
- `config`-level flags the gates read (`enableWorkflow`) — either ride the
  resolved config or pass the supervisor itself as nullable, which mirrors
  today's `supervisor != null && config.enableWorkflow` double gate: the
  factory returns null when the supervisor is absent or the feature off.
  Prefer passing the supervisor and the flag; feature gates stay visible in
  one place (`RuntimeConfig`), not re-derived per factory.

Collection in `buildAgent`:

```dart
final contributed = [
  for (final c in scope.contributions)
    if (c.contribution is AgentToolFactory)
      ...?((c.contribution as AgentToolFactory).build(ctx)),
];
// plugin tools join the base list before the withSubAgents widening,
// so delegate/channel wrap around everything, exactly as today.
```

**Built-in factories**, one plugin each, in `tina_app`:

| Plugin id | Contributes | Gate |
| --- | --- | --- |
| `tina.tools.workflow` | `launch_workflow`, `stop_workflow` | unmounted unconditionally today (spawning_constraints Change 1); was: supervisor wired AND `[features] workflow` |
| `tina.tools.regions` | the seven region tools (`allocate`/`forget` only when the summary index rides the context) | regions registry wired |
| `tina.tools.ask-user` | `ask_user` | asker wired |
| `tina.tools.render-image` | `render_image` | image renderer wired |
| `tina.tools.delegate` | `delegate` + channel tools (the `withDelegateTool`/`withChannelTools` pair) | `withSubAgents` — passed as a build flag, mirroring today |

**Ordering.** Plugin-id sort decides registration order among factories, so
contributed tools land in a deterministic order after the base list. The
frozen catalog (`kWorkspaceToolCatalog`) is untouched — these are not
catalog tools. If a future collision (a contributed tool sharing a catalog
name) must throw, `toolRegistryFromScope`'s collision rule is the model;
`buildAgent` adopts the same explicit-throw.

**Orchestrators stay fail-closed for free.** `OrchestratorToolGuard` blocks
every name it does not allow-list, so plugin-contributed tools cannot leak
into orchestrator turns by existing. The orchestrator path simply does not
collect factories (it builds from vetted concrete tools by design —
`orchestrator_tools.dart`'s rationale is unchanged).

**Sub-agent inheritance rides the existing mechanism.** Delegated builds
already mount the scheduler's scope-resolved contributions
(`sub_agent_scheduler.dart`); `AgentToolFactory` contributions flow the same
way, so a project plugin's tool reaches sub-agents identically.

## Migration

1. Add `AgentToolFactory`; teach `buildAgent` to collect (no behavior change
   — nothing contributes yet).
2. Move the six surfaces to built-in factories, one plugin per commit,
   deleting the matching `tools.add(...)` block each time. Goldens stay
   green after every commit.
3. Delete the last imperative block; `buildAgent`'s tool section is now:
   base list from scope + factory contributions + the `withSubAgents`
   policy widening.

## Validation

- Goldens (README invariant) green after each migration step.
- A test plugin contributing a tool appears in interactive mains and in
  delegated sub-agents (factories flow through the scheduler's inherited
  scope), appears headless only for surfaces that do not gate on
  `withSubAgents` (the delegation factory returns null there, matching
  today), and is blocked in orchestrator turns.
- `[features] workflow = false`: workflow tools absent from the registry
  and from the permission table (PT2 makes the second half automatic).
- Teardown: revoking `tina.tools.workflow`'s registration mid-run does not
  corrupt an in-flight build (tools are captured at build start; the next
  build sees the change).
