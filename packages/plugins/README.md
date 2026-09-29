# Plugin packages

Each directory is a Dart package with its own public API and tests.

| Package | Owns |
| --- | --- |
| `tina_providers` | Provider pools, request scheduling and token budgets |
| `tina_self_update` | `/update`, verified preparation and approved bundle replacement |
| `tina_approvals` | Channel-independent approval service and stream channel |
| `tina_approvals_tui` | Console approval delivery and dialogs |
| `tina_persistence` | Session store, append subscription, metadata and resume |
| `tina_tools` | File/process tools, sandbox permissions, `ToolsPlugin`, `/mode` |
| `tina_persona` | Agent identity prompt section |
| `tina_compaction` | Context summarization and compaction |
| `tina_plans` | Plan state, `update_plan`, `/plan` |
| `tina_goals` | Goal state, judging, `/goal` |
| `tina_subagents` | Child-session scheduling, spawn tool and child assembly |
| `tina_file_resources` | Folder-backed prompt resources, including skills |
| `tina_workflows` | Optional Attractor-backed workflows; deferred from the new app |
| `tina_index` | Code graph extraction and querying; existing library API retained |

Plugins extend `AgentPlugin` from `tina_engine_2`. It provides prompt/turn hooks,
`openSession`/`closeSession` for resource ownership, `mountOn` for executor
registration and session subscriptions, and a `commands` getter.
The host mounts plugins and collects commands without importing any
concrete plugin package. The loop only depends on `tina_core`.

`Command` and `Terminal` are shared contracts in `tina_core`. `Commands`, the
registry, belongs to `tina_host`. A plugin receives its terminal, approver or
other dependencies through its constructor. There is no service locator.
Command dispatchers await asynchronous handlers.

Plugin IDs use lowercase `publisher/name`, for example `tina/persistence` and
`acme/search`. The `tina` namespace is reserved for factories supplied by the
application assembly; extension registration cannot claim it. This is a naming
rule for trusted plugins, not a sandbox for arbitrary Dart code.

The global `~/.tina/config` selects feature plugins through `[plugins].enabled`.
The TUI defaults to `tina/persistence`, `tina/plans`, `tina/goals`,
`tina/auto-compact`, `tina/subagents` and `tina/update`; `tina/file-resources` is opt-in.
Persona, provider policy, tools and mode remain the base plugins. Config selects registered
factories; it does not download or dynamically import Dart packages.

`tina_index` keeps serving existing callers; this move does not introduce an
index plugin adapter. Attractor stays at `packages/libraries/attractor`, available to
the workflow plugin and legacy app, but absent from the new app's runtime graph.

## Plugin descriptions

Every catalog entry requires a nonempty, user-facing `description` on its
`PluginDefinition`. Settings → Plugins reads this metadata without constructing
or enabling the plugin. Highlight a checkbox to see the blurb; press `?` for the
full description on a small terminal. Required host plugins have descriptions too.

```dart
registry.register(
  'acme/review',
  (context) => ReviewPlugin(context),
  description: 'Reviews local changes and highlights likely bugs.',
  live: true,
);
```

Both `PluginDefinition(...)` and `PluginDefinition.dependingOn(...)` require
`description:`. Blank descriptions are rejected. First-party catalogs use the
same definition objects, including description and lifecycle policy; factory-only
maps are no longer supported. The engine loop has no dependency on this metadata.
