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
append `--insecure-checksum-only` for checksum-only verification). Installs to
`~/.local/bin` (override with `--dir`), and you can pin a version with
`--version v0.6.1`. The script's header documents its trust model: the pinned
key detects tampered release assets, not a compromised GitHub account.

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

`/index` classifies programming languages only. It visits the directory tree,
classifies each directory's own files, and merges the findings up to the project
root. Unchanged results are restored from `.tina/classifications`; changed
branches are recomputed without reclassifying their siblings. `/index status`
checks saved results without model calls; `/index refresh` recomputes them.
Language decisions come from the classifier. Indexing does not generate region
summaries or launch a setup conversation.

## Running inside tmux

Run `tmux new -s tina && tina` and `/detach` (or **Alt+D**) returns to the shell
with the agent still running; reattach any time with `tmux attach -t tina`.
`/exit` inside tmux offers Detach / Exit / Cancel. Outside tmux nothing changes
— see [`docs/features/session_attach_detach.md`](docs/features/session_attach_detach.md).

## Architecture

See [`ARCHITECTURE.md`](ARCHITECTURE.md) and [`docs/`](docs/) for design notes.

## License

MIT — see [LICENSE](LICENSE). The bundled terminal rendering comes from
[dart_notcurses](https://github.com/nmfisher/dart_notcurses) (separate license).
