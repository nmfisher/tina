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

Choose the panel layout at startup with `tina --layout sidebar` (the default)
or `tina --layout tiled`. With `dart run`, use `dart run bin/tina.dart --layout tiled`.
Sidebar shows a nested conversation list beside the selected transcript;
tiled shows conversation panels side by side. In sidebar mode, use Ctrl+G
and Left/Right to choose the conversation list, Enter to focus it, then
Up/Down to select a conversation.

To save the preference in `~/.tina/config`:

```toml
[tui]
layout = "tiled"
```

The `--layout` option overrides the saved preference.

On first load, Tina offers to have the main agent set up the project and write
`.tina/ENVIRONMENT.md`. It uses the main conversation's current model, history,
tools, and approvals, and decides whether and how many sub-agents to delegate
to within the configured limits. Ctrl+C cancels the task.

Set `[environment] auto_populate` to `"ask"` (default), `"always"`, or `"never"`
to control that startup behavior. The former `[environment] model` setting is
ignored. `/index` requests setup in the main conversation when the record is
missing or stale; run `/index` again afterward for directory summaries.

Tina marks the record verified only after a completed setup turn creates or
updates the file. Cancelled, failed, or prose-only attempts remain unverified.

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
