# tina_wasm

Wasm implementations of the `tina_core` I/O ports for the engine-on-wasm
program: the HTTP port over the `tina:http` host import (served by the
Rust host in [wasm.dart]), the filesystem and environment ports over WASI
preopens, the process port over the `tina:process` host import (profile
enforced host-side, approval requests crossing back to the engine), and
the clock/random ports as the dart:core defaults the host's WASI
clocks/random back. A native build injects `tina_io` instead; the engine
packages never know which one they hold.

[wasm.dart]: https://github.com/nmfisher/wasm.dart (branch `asb/wasm-stage4-process`)

## Layout

- `lib/src/wasm_http_endpoint.dart` - `HttpClientPort` over `tina:http`
  (streamed bodies: chunks arrive as the network delivers them).
- `lib/src/wasm_file_system_port.dart` - `FileSystemPort` over
  `wasi:filesystem/preopens`; paths resolve against the preopened
  directories and everything else is refused.
- `lib/src/wasm_environment_port.dart` - `EnvironmentPort` over
  `wasi:cli/environment`.
- `lib/src/wasm_process_port.dart` - `ProcessPort` over `tina:process`:
  the access profile travels with every spawn, refusals surface as
  `ProcessRefusedException`, and `ask` verdicts round-trip through the
  configured `ProcessApprover` before the host spawns anything.
- `lib/src/probe_body.dart` + `bin/probe.dart` + `bin/native_probe.dart` -
  the stage-3 exit probe: read a config TOML, write a file, make one
  streaming provider-style call. The wasm and native runs record the same
  lines; their equality is the exit test.
- `lib/src/process_probe_body.dart` + `bin/process_probe.dart` +
  `bin/native_process_probe.dart` - the stage-4 process exit probe:
  `git status` through the host, stdin/env on approved spawns, a denial
  blocked before any process exists.

## Opt-in layout strategy plugin

The TUI leg accepts a layout-strategy component (`tina:layout@1.0.0`,
see `docs/layout-plugin.md` in the tina repository):

```text
--layout-plugin=/path/to/layout_solver.wasm   mount a strategy
--layout-plugin-watch                         re-read the artifact per call
--layout-plugin-deadline-ms=N                 per-solve budget (default 250)
```

With a plugin mounted, every `ScreenLayout` solve routes TUI Store ->
host bridge -> the plugin's own Store (zero capabilities; the host
admits no imports beyond WASI and the contract's types). On absent,
erroring or epoch-killed plugins the bridge reports the fallback and
the guest uses its compiled-in solver - one stderr notice per install.
The artifacts live in `packages/plugins/tina_layout_plugins`.

## Regenerating bindings

    ./tool/generate.sh

The world (`wit/world.wit`) is `wasi:cli/command` plus `tina:http` and the
case-runner protocol. See `wit/README.md` for where the vendored
interfaces come from.

## Running the exit probe

Start the fake provider (a fixed Anthropic-wire SSE stream):

    python3 tool/fake_anthropic_server.py &

Native:

    TINA_LLM_ENDPOINT=http://127.0.0.1:8730 \
    TINA_LLM_TOKEN=probe-token \
      dart run tina_wasm:native_probe

Under wasmtime (compile with `dart run wasm_tools compile
bin/probe.dart` from this package, then run the wasm.dart test_runner):

    target/debug/test_runner bin/probe.wasm \
      --preopen=.<workspace> --env=TINA_LLM_ENDPOINT=http://127.0.0.1:8730 \
      --env=TINA_LLM_TOKEN=probe-token

The recorded lines of the two runs must be identical.

The stage-4 process exit test (`tool/process_exit_test.sh`) follows the
same shape with `bin/process_probe.dart` / `bin/native_process_probe.dart`
in a throwaway git repository: process output, approval round-trips and
denials must record identically under the host and natively.

## The engine component (stage 5)

`bin/engine.dart` is the real headless engine as a component: the same
`SessionAssembly` + `--pipes` protocol the native CLI runs, over the
wasm ports (HTTP via `tina:http`, files via preopens, the portable
tools, config preloaded from the config preopen). Build with
`dart run wasm_tools compile bin/engine.dart`; run with the wasm.dart
`test_runner`, two preopens (`.` = workspace, `config` = config tree)
and `--env` provider credentials. `tool/engine_exit_test.sh` drives one
full agent turn (provider call, `write` tool call, file edit) against
both engines and requires PASS on both.

## Opt-in Wasm prompt plugin

The engine can mount `tina/wasm-prompt`, a live `AgentPlugin` adapter for one host-selected component. Add these flags to the normal engine runner arguments:

```text
--plugin-component=/absolute/path/to/plugin.component.wasm
--plugin-grant=session.read-context
```

The artifact path selects the component. The separate grant allows it to read only the current session ID and model. The runner enables the adapter through the engine environment. Without an artifact, the default plugin set stays unchanged. The sample context-reading plugin fails its prompt hook without this grant, before a provider request or tool execution.

The versioned engine import is `tina:plugin-host/session@0.1.0`. `open` issues a lease. Async `on-prompt` sends a session/model snapshot to the host. The host runs the plugin in its own Store, and the plugin can read that immutable frame through `session.read-context`. The adapter appends the returned section to Tina's actual `TurnContext.promptSections`. The host never calls back into the suspended engine Store. `closeSession` revokes the lease and retires that Store. Reload creates a new adapter, lease and Store.

A newly built engine component requires the updated wasm.dart runner, including when no plugin is configured. The runner keeps the existing Stage 0–6 imports and tested-module protocol. Apply the paired repository changes together.

`bin/plugin_lifecycle_probe.dart` runs inside Wasm with the production adapter, `Host`, `PluginManager`, and `ScriptedProvider`. It checks completed turns, unload with the same session and transcript continuing, stale lease refusal, fresh reload, and repeated close of an old adapter. Its checks throw in product builds. Build it through the same hook as `bin/engine.dart`, then run with `--no-stdin` and the two plugin flags above. It needs no provider server or filesystem preopens.

The engine's owner API supports live plugin selection. New pipes/TUI plugin-management controls and compile-on-load are not part of this slice. Epoch interruption, memory budgets and cancellation of active guest execution remain open. The current async import offloads synchronous plugin execution to Tokio's blocking pool; synchronous open/close can still wait for that execution.
