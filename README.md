# Tina

> **Tina Is No Agent.** (And *Tina Is No Acronym* — the recursion stops when you want it to.)

Tina is a terminal UI for driving multiple LLM coding agents at once — a
[notcurses](https://github.com/dankamongmen/notcurses)-based TUI for composing,
spawning, and metering agent sessions side by side, with scrollback, session
persistence/resume, and live spend metering across a fleet of sub-agents.

<!-- TODO: refine this pitch in your own words. -->

## Install

Prebuilt bundles (Linux x64/arm64, macOS arm64) are attached to each
[release](../../releases). Unpack and run:

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
