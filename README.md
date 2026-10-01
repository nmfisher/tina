# Tina

Tina is a terminal coding agent. The root `tina` executable now runs engine2:
one agent loop, with tools, persistence, plans, goals, compaction, subagents,
provider policy and updates supplied by plugins.

## Install and run

```sh
curl -fsSL https://raw.githubusercontent.com/nmfisher/tina/main/install.sh | sh
tina --configure
tina --cwd /path/to/project
```

The installer downloads the latest **published** release; a checkout's cutover
changes become available there only after a release is published. It verifies
the release manifest with minisign (install `minisign`, or explicitly choose
`--insecure-checksum-only`). Supported bundles: macOS arm64, Linux x64 and arm64.
The private bundle is `${XDG_DATA_HOME:-~/.local/share}/tina`, with a launcher
symlink at `~/.local/bin/tina`. `--dir` and `--bundle-dir` override these locations.

The first launch without config opens settings. Choose a provider and model,
supply credentials in settings or the provider's environment variable, save,
then launch Tina. `/settings` edits global settings for the next launch.

## Configuration and plugins

Global config is TOML at `~/.tina/config`; `--config FILE` overrides that path.

```toml
version = 1
[default]
provider = "anthropic"
model = "your-model-id"
max_tokens = 8192

[plugins]
approval_channel = "tina/approvals-tui"
enabled = ["tina/persistence", "tina/plans", "tina/goals",
           "tina/auto-compact", "tina/subagents", "tina/update"]
```

Open `/settings` → **Plugins** to enable or disable plugins with checkboxes.
Choose Global, Workspace or Session scope; Space/Enter toggles, Ctrl-R restores
inheritance. Changes save immediately and supported plugins load/unload live.
Required plugins are locked; restart-only changes are marked pending restart.

Session overrides take precedence over workspace, then global. Workspace config
is `<workspace>/.tina/config`, with per-ID `[plugins.overrides]`; provider/model
settings stay global. Config chooses registered plugins, not downloaded code.
Names use `publisher/name`, with `tina/` reserved for first-party plugins.

UI plugins can register settings sections and other console contributions;
see [UI contribution interfaces and lifecycle](docs/ui-contributions.md).

MCP servers, including Blender Lab's official server, are supported by `tina/mcp`.
Configure them in Settings → MCP servers; see [MCP setup](docs/engine2-mcp.md).

See [configuration reference](docs/engine2-config.md) for pools, rates, token
limits, reasoning/output controls, themes, credentials and completion.

## Input, commands and sessions

Type during a turn and press Enter to queue another input. Queued inputs run in
order; unfinished text stays in the editor. Escape clears the draft first;
Escape with an empty draft cancels the active turn. Tools show status and live
subprocess output. Approval dialogs use the selected approval-channel plugin.

`/help` lists commands from the loaded plugins. `/` completes command names;
Tab offers argument completions supplied by each plugin. `@` completes files.
Settings menus filter as you type, and Tab completes supported text fields.

`/spawn` opens an independent conversation panel using the current model;
`/spawn provider/model` selects a different model. Each panel keeps its own
draft, input history, queued messages and saved session. Panels can run turns
concurrently. Wide terminals show two panels side by side; narrow terminals
show the selected panel.

- Ctrl+G or Ctrl+W enters panel navigation: arrows/Tab select, Enter focuses,
  Escape cancels navigation.
- Ctrl+O toggles the selected panel between full width and the split layout.
- Ctrl+X or `/close` closes the focused panel and cancels its running turn.
- `/panels` lists open panels; `/quit` exits the whole application.

This is supplied by the default `tina/panels-tui` UI plugin. If your config has
an explicit enabled-plugin list, add it and restart. Saved conversations can
be resumed individually; the arrangement of open panels is not persisted.

```sh
tina --resume                       # list and select a workspace session
tina --continue                     # continue the most recently updated session (-c)
tina --resume SESSION_ID            # continue a saved session
tina --store /path/to/sessions.db    # override the SQLite store
tina --completion zsh               # bash and fish also supported
```

New sessions live in `<workspace>/.tina/sessions.db`. Old session files are left
intact; use `--import-sessions PATH` to convert them first (see the
[import guide](docs/engine2-session-import.md)). The old session
slash commands have deliberately not been ported.

Shift-Tab cycles **ask → read-only → allow-edits → auto**; `/mode NAME` selects
one directly. The single `tina/mode` plugin owns both the permission policy and
its console attachment. Auto reviews tool operations with a safety judge and
asks you when the judge denies or cannot decide. See the
[mode plugin](packages/plugins/tina_mode/README.md) for exact behavior.

`/update` checks for a release. `/update install` downloads, requires a matching
SHA-256 checksum, validates the archive, then requests approval through the
configured channel before replacing a marked private bundle. Restart afterward.
This is checksum verification over HTTPS; the command does not verify minisign
signatures. The installer above supports signature verification.

## Build and test

```sh
git clone --recurse-submodules https://github.com/nmfisher/tina.git
cd tina
dart pub get
./tool/build_bundle.sh host
python3 tool/smoke_engine2.py --binary build/cli/macos_arm64/bundle/bin/tina
```

Requires Dart 3.12 or later. The build script also supports `linux-x64`,
`linux-arm64`, `macos-arm64` and `all`; Linux builds use Docker. Release CI runs
terminal smoke tests against each built target before packaging.

Input classification is supplied by `tina/classification` (see the configuration
reference). Repository classification and indexing remain deferred. Workflows/Attractor remain
available as packages for legacy callers, disconnected from engine2. See
[migration status](docs/engine2-migration.md), [package architecture](ARCHITECTURE.md)
and the [legacy CLI reference](docs/legacy-cli.md).
