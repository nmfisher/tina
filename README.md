# Tina

> **Tina Is No Agent.** (And *Tina Is No Acronym* — the recursion stops when you want it to.)

Tina is a terminal UI for driving multiple LLM coding agents at once — a
[notcurses](https://github.com/dankamongmen/notcurses)-based TUI for composing,
spawning, and metering agent sessions side by side, with scrollback, session
persistence/resume, and live spend metering across a fleet of sub-agents.

<!-- TODO: refine this pitch in your own words. -->

## Install

One-liner (Linux x64/arm64, macOS arm64) — verifies a minisign signature over
the release checksum manifest before installing anything:

```sh
curl -fsSL https://raw.githubusercontent.com/nmfisher/tina/main/install.sh | sh
```

Requires `curl` or `wget`, a `sha256` tool, and `minisign` for signature
verification (`apt install minisign` / `brew install minisign`; without it,
append `--insecure-checksum-only` for checksum-only verification). Installs the
bundle in `${XDG_DATA_HOME:-~/.local/share}/tina` and a symlink launcher at
`~/.local/bin/tina`. Override the launcher directory with `--dir` or
`TINA_INSTALL_DIR`, and the private bundle with `--bundle-dir` or
`TINA_BUNDLE_DIR`. You can pin a version with
`--version v0.6.1`. The script's header documents its trust model: the pinned
key detects tampered release assets, not a compromised GitHub account.

`/update` replaces only the private bundle; restart Tina afterward. For an older
install with the binary directly in `~/.local/bin` and libraries in
`~/.local/lib`, re-run the installer above once to migrate. It replaces the Tina
launcher and leaves shared libraries and other applications untouched.
Configuration and sessions remain in `~/.tina`.

Prebuilt bundles are also attached to each
[release](../../releases) to unpack by hand:

```sh
tar xzf tina-<tag>-<target>.tar.gz
./bundle/bin/tina
```

## Build from source

Requires a Dart SDK ≥ 3.12. Clone with submodules (the `dart_notcurses` native
binding is required):

```sh
git clone --recurse-submodules https://github.com/nmfisher/tina.git
cd tina
dart pub get
dart build cli -t bin/tina.dart        # bundle lands in build/cli/<os>_<arch>/bundle/
```

For cross-platform bundles (Linux via Docker, macOS native):

```sh
./tool/build_bundle.sh host            # or: linux-x64 | linux-arm64 | macos-arm64 | all
```

## Configuration

Tina writes its config, sessions, and caches under `~/.tina/`. Run `tina --setup`
to configure providers and API keys.

Choose the panel layout at startup with `tina --layout tiled` (the default) or
`tina --layout sidebar`. With `dart run`, use `dart run bin/tina.dart --layout sidebar`.
Tiled shows conversation panels side by side and leaves the transcript the full
width; sidebar additionally reserves a left column holding a nested conversation
list beside the selected transcript, at the cost of 24 columns. In sidebar mode,
use Ctrl+G and Left/Right to choose the conversation list, Enter to focus it,
then Up/Down to select a conversation.

To save the preference in `~/.tina/config`:

```toml
[tui]
layout = "sidebar"
```

The `--layout` option overrides the saved preference.

`read-all` mode blocks shell commands, file edits, workflow launches, and
full-access delegation without an approval prompt, including previously allowed
commands. Switch modes to enable execution. Dedicated inspection tools remain
available. Mode changes also apply to delegated agents and workflow nodes.
Tool schemas and the system prompt stay unchanged across mode changes; mode notices are appended to the conversation to preserve earlier
request prefixes for prompt caching.

`/index` classifies languages, frameworks and tooling, merging directory results
up to the repository root. Language detection defaults to local extension
matching; `/index jev` uses Typesafe/JEV for languages too. Framework and tooling
classification uses Typesafe/JEV with selected manifests and configuration files.
Configure Typesafe in `/settings` or set `TYPESAFE_API_KEY`; without it, language
indexing still works and the other classifications are reported as unavailable.
Unchanged results restore from `.tina/classifications`. `/index status` checks
saved results without model calls; `/index refresh` recomputes them.
`/index view` opens a paged directory tree from SQLite, with saved labels and
on-demand evidence and classifier details. It does not scan the repository or
need model credentials; use `/index status` to check freshness.

## Running inside tmux

Run `tmux new -s tina && tina` and `/detach` (or **Alt+D**) returns to the shell
with the agent still running; reattach any time with `tmux attach -t tina`.
`/exit` inside tmux offers Detach / Exit / Cancel. Outside tmux nothing changes
— see [`docs/features/session_attach_detach.md`](docs/features/session_attach_detach.md).

## Architecture

See [`ARCHITECTURE.md`](ARCHITECTURE.md) and [`docs/`](docs/) for design notes.
UI plugins can customize transcript blocks through typed
[`Renderer<T>` contributions](docs/features/renderers.md).
Execution plugins can register static or lazy skills through the scoped
[skill registry](docs/features/skills.md).

## License

MIT — see [LICENSE](LICENSE). The bundled terminal rendering comes from
[dart_notcurses](https://github.com/nmfisher/dart_notcurses) (separate license).
