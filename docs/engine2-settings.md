# Scoped settings

`tina_settings` is a pure Dart library in `packages/libraries`. Plugins declare
typed, namespaced `SettingDefinition`s on their `PluginDefinition.settings`.
Definitions are available without constructing or enabling a plugin. The engine
has no settings dependency; the host supplies each session's `ScopedSettings` to
the plugins that need it.

## Editing and inheritance

Open `/settings`. The header shows the editing scope; Tab cycles Session,
Workspace and Global in menus. Fields show their value and where it comes from.
Select a field to set an override or choose **Use inherited value** to remove it.
An explicit value equal to the inherited value still creates an override.
Confirmed edits save immediately. Generation forms save on Enter and cancel on
Escape. In Plugins, Space/Enter toggles and Ctrl-R removes an override; `?` shows
the full description.

| Scope | Storage | Applies to |
|---|---|---|
| Session | Opaque settings snapshot in the session log, saved by `tina/persistence` | This conversation; restored on resume |
| Workspace | `<working-directory>/.tina/config` | Conversations in this workspace |
| Global | `~/.tina/config`, or the explicit `--config` file | All conversations using that file |
| Default | Plugin definition | Used when no override exists |

Resolution follows Session → Workspace → Global → Default. Editing a lower scope
shows that scope's resolved value, even if a session override masks it. Global
and workspace changes refresh other open panels immediately; other processes
and external edits are picked up within about one second. File saves preserve
unrelated config/credentials, reject stale snapshots, and replace files atomically.

Scopes define configuration inheritance, not shared usage counters. Requests per
minute and token limits are enforced per conversation and its subagents. Setting
a Global limit supplies the same default to conversations; it does not combine
their counters into a process-wide or cross-process quota.

## Scope eligibility and application

| Setting | Supported scopes | Takes effect |
|---|---|---|
| Request/token limits, output/thinking, step limit, subagent limits | All | Next request/spawn |
| Auto-approval classifier instruction | All | Next classification request |
| Plugin enablement | All | When idle if live; otherwise restart |
| Default provider/model | Global, Workspace | New conversations; `/model` changes the current one |
| Approval delivery | Global, Workspace | New conversation/restart |
| Theme | Global | Immediately across the terminal |
| Provider catalog/credentials and MCP server configuration | Global | Existing specialized editors apply their changes |

A plugin lists eligible scopes and explains restrictions with `scopeReason`.
The editor offers a supported scope when the selected one is unavailable.
Actions and temporary controls remain UI contributions with callbacks; they do
not acquire inherited configuration merely because they appear in Settings.
Provider identities/credentials use the specialized Global editor. This pass
does not move credentials into session snapshots or workspace files.

## Plugin API

```dart
final instruction = SettingDefinition<String>(
  id: 'acme/reviewer/instruction',
  label: 'Review instruction',
  description: 'Instruction used by the reviewer on its next request.',
  defaultValue: '',
  kind: SettingKind.text,
  scopes: {SettingScope.session, SettingScope.workspace, SettingScope.global},
  applyAt: ApplyAt.nextRequest,
);

registry.registerDefinition(PluginDefinition<Context>(
  'acme/reviewer',
  (context) => ReviewerPlugin(context.settings),
  description: 'Reviews requested changes.',
  settings: [instruction],
));

// The plugin reads at the request boundary, or subscribes to changes.
final value = settings.read(instruction); // value.value and value.source
settings.set(instruction, 'Use concise reviews', SettingScope.session);
settings.removeOverride(instruction, SettingScope.session);
final detach = settings.watch(instruction, (resolved) => apply(resolved.value));
// Call detach when the plugin unloads/closes.
```

Kinds cover toggles, integers, text, choices and composite objects. Definitions
specify defaults, descriptions, validation, numeric bounds, secret presentation
and application timing. Generic editors are generated from installed metadata.
`ScopedSettingControl` also binds a definition and resolver to a plugin's custom
`SettingsSection`. Existing `SettingAction` and callback controls remain available.
`scopes` on a callback control documents an eligibility restriction; the plugin
still owns its custom storage and callback behavior.

`SettingsBackend` stores encoded values by setting ID. The TUI adapter maps them
to existing TOML keys using optional `configPath` or composite read/write hooks.
New definitions default to `[plugin_config."acme/reviewer"]` plus their last ID
segment. `MemorySettingsBackend` supports tests or embedders. Validation runs
before writes; `watch` receives effective value/origin changes, and returns its
cleanup function. Masked lower-scope changes still refresh the UI without
reapplying the session's effective value.

## Auto-approval instruction

Open `/settings` → **Mode and auto approval** → **Auto-approval classifier
instruction**. For example: “I'm ok with writing files to any directory outside
the working directory.” Keep Session scope to save it only with this conversation.
The instruction is prepended to every permission classification request,
including constrained-output retries. It is read again for each request, so edits
take effect without restarting. It guides the auto-approval verdict; it does not
change the active mode, grant a remembered permission, or disable the OS sandbox.
Input intent classification is separate from this permission classifier.
