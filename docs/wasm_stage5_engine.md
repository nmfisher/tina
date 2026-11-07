# Stage 5 — the real engine on wasm (engine-on-wasm program)

Stage 5 componentizes tina's actual headless engine: the same
`SessionAssembly` and `--pipes` protocol the native CLI serves build as
a wasm component and complete a full agent turn under wasmtime.

## What landed (tina, `asb/wasm-stage5-engine`)

### The app layer became injectable (no ratchet change)

The Stage-2 ratchet (no `dart:io` in engine packages) is untouched; the
app layer (`apps/tina_cli`) moved its own `dart:io` behind seams so the
headless path compiles where `dart:io` does not exist:

- `app_io.dart` — a synchronous application I/O interface (env, home,
  cwd, read/write/create/rename/delete/secure-permissions), with the
  native implementation selected by `dart.library.io` conditionals and
  a wasm composition root injecting a preloaded snapshot
  (`injectedAppIo`). `assembly_config`, `config_document`,
  `configured_provider`, `legacy_provider_cache`, `plugin_settings`,
  `scoped_config` reads/writes, and the assembly boot all go through it.
- `native_kinds.dart` — `ToolsPlugin` and `ConfigSettingsBackend` are
  the real classes natively and clean aliases (the engine's plugin
  base, the settings interface) under wasm, so one `SessionAssembly`
  compiles on both platforms and the native surface stays reachable
  for the app and tests.
- `settings_stack.dart` — an injectable settings backend (with a
  standard layer merge, `mergeSettingLayers`, shared with the native
  backend), and `settings_catalog` off the full plugin registry.
- `tools_factory.dart`, `provider_default.dart`, `persistence_seam.dart`,
  `pipes_stdio.dart`, `app_stdout.dart` — injectable factories and
  conditionals for the native-only constructions (the full ToolsPlugin,
  the sqlite persistence, the default HTTP endpoint, the pipes stdio).
- `session_context.dart` — `SessionPluginContext` split out of the
  plugin catalog, which imports every first-party plugin (including the
  terminal-only ones).
- The stage-1 `--pipes` branch is merged in (the protocol the exit test
  drives); `pipes.dart` itself takes injected input/emit and no longer
  touches `dart:io`.

### The plugins got clean where it was cheap

- `tina_tools`: `portable_tools.dart` — the real read/write/edit tools
  and the filesystem seam with no `dart:io` in the graph; a
  `defaultFileSystem` conditional; one exception type (`ToolFsException`)
  across implementations.
- `classification`: the precedent store's file I/O behind a conditional
  seam (`permissions.dart` stays importable where `dart:ffi` cannot go).

### The wasm composition root (`packages/libraries/tina_wasm`)

`bin/engine.dart` — the engine component: preload the preopened config
tree and `.tina` into a synchronous `PreloadedAppIo` (the assembly boot
is a chain of synchronous constructors), inject the portable tools
plugin (`WasiToolFileSystem` over the workspace preopen) and the wasm
plugin registry, build the provider over `tina:http` with credentials
from the host-set environment, run `runSessionPipes` over WASI
stdin/stdout (writes serialized; the queue drains before the export
returns). Tools: `engine_exit_test.sh`, `pipes_drive.dart`,
`fake_anthropic_turn_server.py`.

## The exit test (recorded)

`tool/engine_exit_test.sh` drives BOTH engines with the same client:

```
=== native engine (dart run bin/tina.dart --pipes)
[drive] ready: session=s-... / [drive] file written: true
[drive] file content: stage5 edit landed / [drive] saw tool call: true
[drive] tool completed: true / [drive] RESULT: PASS
=== wasm engine under wasmtime
[drive] ready ... [drive] file content: stage5 edit landed
[drive] RESULT: PASS
STAGE-5 EXIT TEST: both engines completed the turn
```

One full turn each: provider call (fake Anthropic, two scripted steps),
`tool_use` (`write`), the file lands inside the preopen/workspace, the
final answer, `shutdown`. No credentials anywhere: the endpoint and
token come from `--env` at host launch.

## Measurements (see wasm.dart `docs/stage5_component.md` for the box)

- component 1,822,499 bytes; rebuild 7.3 s warm (~21 s cold);
- startup to first `ready`: ~2-8 s direct, 75.4 s from a spawned
  runner (this sandbox adds a ~45 s grandchild-process delay; the
  debug-build runner's cranelift JIT is the rest);
- peak RSS 363 MiB for the runner process (boot + turn).

## Deviations and open unknowns

- The wasm registry is the portable subset (system-instruction,
  providers, mode, portable tools, approvals-stream,
  session-controls). Remaining slices: process tools over the
  `tina:process` host import, glob/ls/stat, persistence (sqlite is
  FFI), classification's model classifiers, shell/MCP/self-update/TUI.
- `PreloadedAppIo` answers boot reads from a snapshot; runtime writes
  are held in memory (the exit-test session writes no configuration).
  A WASI-backed synchronous story (or an async settings backend) is a
  follow-up.
- The native `tina` entry keeps its full behavior; the wasm engine is
  a second composition root over the same assembly code, not the same
  entry binary (the TUI cannot compile where `dart_notcurses` cannot).
- Precedent-store persistence, config writes and the permission store
  are session-only under wasm for now.
- Local development needed a `hooks` override in (uncommitted)
  `pubspec_overrides.yaml`: wasm_tools wants hooks ^2, the
  dart_notcurses submodule wants ^1.
