# tina_tui

The engine2 terminal application. The root executable calls `runCli` from this package. `bin/tina_tui.dart` reads configuration,
constructs `TuiAssembly`, and runs the console through `TuiSession`.
The loop remains in `tina_engine_2`; terminal code stays here, in `tina_console`, and in frontend plugin packages.

From this directory:

```sh
dart pub get
dart run bin/tina_tui.dart --config ~/.tina/config --cwd /path/to/project
```

The global configuration is `~/.tina/config`, overridable with `--config`.
It uses TOML; see [the configuration reference](../../docs/engine2-config.md) for supported settings:

```toml
version = 1
[default]
model = "your-model"

[plugins]
approval_channel = "tina/approvals-tui" # default
enabled = [
  "tina/persistence",
  "tina/plans",
  "tina/goals",
  "tina/auto-compact",
  "tina/subagents",
  "tina/update",
]
```

A bare model uses the Anthropic wire with `TINA_LLM_ENDPOINT` and
`TINA_LLM_TOKEN` (or Anthropic credential environment variables).
Built-in provider descriptors can also be selected with `provider`.
Legacy `[providers.<id>]` tables now support `name`, `wire`, `base_url`,
`api_key`, `auth_token`, `models` and `disabled_models`. A new provider defaults
to the OpenAI-compatible wire and requires a base URL. Setting `wire` on a
built-in also requires a base URL. Supported wires are `anthropic`, `openai`
and `gemini`. For example:

```toml
[default]
provider = "local"
model = "vendor/model"

[providers.local]
wire = "openai"
base_url = "http://localhost:8080/v1"
models = ["vendor/model|My model"]
# api_key = "..."  # alternatively set LOCAL_API_KEY
```

Configured credentials and endpoints override environment values. Environment
fallback uses the provider's built-in key variable or `<PROVIDER_ID>_API_KEY`,
`<PROVIDER_ID>_AUTH_TOKEN` and `<PROVIDER_ID>_BASE_URL` (uppercase, hyphens become
underscores). Anthropic `api_key` uses `x-api-key`; `auth_token` uses bearer auth.
Model labels after `|` are display-only. Disabled models are omitted from the
settings picker; explicit model IDs remain usable.
The default model label `scripted` still uses the real provider factory;
it is not an offline demo provider.

The list above is the default when `[plugins].enabled` is absent. An explicit
list with `selection_version = 2` replaces the full selection. Older configs
retain their formerly implicit base plugins for compatibility. Requirements are
derived from capabilities: the application needs a model provider, and enabled
consumers need their declared providers. Add `tina/file-resources` to load workspace `.tina/skills`.
Unknown, duplicate or unqualified plugin IDs fail at startup. Malformed or
unsupported configuration fails before a session is created.

Plugin scope is resolved per ID: session overrides workspace, workspace overrides
global, and global overrides built-in defaults. Workspace overrides live in
`<working-directory>/.tina/config`; only plugin overrides and the approval channel
are read from that file. They do not replace provider/model settings. For example:

```toml
# <workspace>/.tina/config
[plugins.overrides]
"tina/goals" = false
"tina/file-resources" = true
```

The same `[plugins.overrides]` table is accepted globally, above the existing
`[plugins].enabled` baseline. Missing entries inherit. Workspace `enabled` lists
are rejected so workspaces never need to copy the global list. `--config` replaces
the global config path; workspace overrides still apply. When both paths identify
the same file it is read once as the explicit global file, and Workspace-scope
writes are refused to avoid silently treating one file as two scopes.

Settings → **Plugins** lists registered plugins with enable/disable checkboxes,
active state, source scope, pending changes and a description of the selected
plugin. Press `?` to read the full description. Choose Global (default), Workspace
or Session scope. Space/Enter toggles; Ctrl-R removes that scope's per-ID override
and restores inheritance. Changes save immediately. Session
changes stay in memory and are not restored with session history. Global and
workspace changes are saved atomically, preserve unrelated config, and apply to
the current session where live changes are supported. Other running processes
are not automatically reconfigured. A higher scope can mask a persisted change;
the checkbox shows the selected scope while the row also shows active state.

Plans, goals, auto-compaction and file resources support live enable/disable.
Changes requested during a turn wait until it finishes. Unload removes commands,
executors, hooks, subscriptions and frontend contributions; reloading creates a
fresh instance and lets the plugin replay its state from the transcript. Failed
activation cleans partial registrations and leaves existing plugins loaded.
Persistence and subagents require restart; their configured and loaded states
can therefore differ. The system-instruction plugin is optional. Settings show
which enabled consumer or application capability requires each provider.
Dependency validation rejects removing a provider while its consumers remain enabled. Channel changes use the approval-channel
setting and require restart.

Plugin authors opt into live changes with `PluginDefinition(live: true)` (or
`registry.register(..., description: "...", live: true)`). Every definition
requires a nonempty `description`, available even while the plugin is disabled. `closeSession` must terminate their resource
and background-work lifecycle. Registrations made synchronously during `mountOn`
are automatically owned by the plugin; subscriptions created later must be
released by its lifecycle. The loader defaults unfamiliar plugins to restart-only.
The Plugins settings submenu selects already registered factories; it does not install or download
Dart packages.

IDs use `publisher/name`; `tina/` is reserved for first-party factories.
Embedding applications can register other publishers through the assembly's
`registerPlugins` callback. Config selects registered factories and does not
download code or import arbitrary packages.

`/settings` edits the global default provider/model, provider tables and enabled
global plugin list and approval channel. Replacing the global list clears global
per-ID overrides; workspace and session overrides remain independent. Credentials are masked. Save validates the draft, preserves
unrelated legacy tables, detects external edits and atomically replaces the
file with owner-only permissions on POSIX. TOML formatting/comments are
normalized on save. Escape discards the draft. Changes apply on next launch;
settings does not switch the active session or reload plugins.

Provider pooling is rejected explicitly. Legacy rate limits, quotas, theme and
reasoning settings are preserved on save but are not implemented by this editor
or wired by the new assembly. Workflow configuration stays deferred.

With defaults, `/plan`, `/goal`, `/mode`, `/settings` and `/quit` are registered.
`/` completion reads that command registry; `@` completion reads workspace
paths. The selected approval channel handles permission requests. The default
`tina/approvals-tui` supplies the console dialog. `tina/approvals` tracks pending
requests and `tina/tools` enforces decisions; application code mounts generic
console contributions and does not wire sandbox callbacks.

`[plugins].approval_channel` selects exactly one registered channel provider,
independently of optional feature plugins. `enabled = []` still has approval
handling. Missing, duplicate and cyclic capability dependencies fail before
plugin factories run. No attached frontend or transport means denial.

The built-in `tina/approvals-stream` exposes requests to an embedding transport;
it does not send SMS or open a network listener. A transport subscribes to its
`requests` stream and calls `respond(request.id, decision)` after authenticating
the responder. A third-party channel plugin can provide the same capability.
Requests expire after five minutes by default, are cancelled with their turn or
session, and reject late or duplicate replies. They are not persisted across
restarts. See [approval plugin](../plugins/tina_approvals/README.md) for the
registration and transport contracts.

Dialogs fit the available screen space and keep the selected choice visible.
Tab opens full request details; arrows scroll, Tab or Enter returns to choices,
and Escape denies. Resizing preserves the current choice and details view.
Replies stream into the conversation as text arrives. Escape cancels the active
turn; another turn can then be submitted. Resizing reflows the conversation and
preserves the current input draft. Interrupted reply text remains in the log.
The workflow plugin is preserved separately in `tina_workflows`, still backed
by Attractor. The new app depends on neither package and does not mount it.

## Sessions

`tina/persistence` owns session storage and defaults to
`<working-directory>/.tina/sessions.db`. The application assembly supplies its
store opener; the host has no filesystem or SQLite dependency. Override the
location with `--store FILE`. List or resume using the default location:

```sh
dart run bin/tina_tui.dart --cwd /path/to/project --resume
dart run bin/tina_tui.dart --cwd /path/to/project --continue
dart run bin/tina_tui.dart --cwd /path/to/project --resume SESSION_ID
```

Use `--import-sessions PATH` to convert legacy files into the new store;
`--dry-run` previews without writing. The source files remain unchanged.
`--store`, resuming and continuing require persistence to be enabled.
Bare `--resume` prints a numbered picker before loading the app; Enter/q
cancels. `--continue` (or `-c`) resumes the last updated main session.

## Verification

```sh
dart analyze
dart test -j 4
dart test --tags tty --run-skipped test/app_smoke_test.dart
```

The PTY test starts the actual entry point with isolated config and a localhost
Anthropic response stub. It checks startup, mode display, command suggestions,
partial output before model completion, resize during streaming, cancellation
of a stalled request followed by another turn, compact approval denial and
remembered approval, settings open/resize/close, listing/resume, terminal
restoration and process exit with stdin still open. It starts at 80×10, 80×24
and 120×30 and resizes through 100×20, 40×8 and 80×10. Its provider endpoint and
API key come from a temporary custom provider table. It needs Python 3, a POSIX PTY and local
socket access, but no API credentials or external model service.

It can also be run from the repository root:

```sh
python3 tool/smoke_engine2.py --dart /path/to/dart
```

Use the same Dart SDK as the package's build hooks. This checks terminal byte
I/O and lifecycle; human visual acceptance and the remaining interaction
features still need work. Session commands are deliberately deferred.
See [migration status](../../docs/engine2-migration.md).

The root CLI supports `--configure`, `--version`, and `--completion bash|zsh|fish`.
Command arguments are completed by plugin-owned `Command.complete` callbacks.
Settings menus filter as you type; Tab completes supported text fields.
