# The wasm stack on one page

This page maps every layer that turns Tina's Dart code into a sandboxed wasm program.
It is the permanent quick reference.
Facts were checked against the two trees on 2026-11-13.

## The four outside layers

These layers are built by others. We do not change them.

- **wasmtime** (Bytecode Alliance, Rust). The executor and the sandbox.
  It is a library you embed, not a program you run.
  Pinned at 47.x.
- **dart2wasm** (Google). The compiler.
  It ships inside the Dart SDK.
  It turns Dart source into a core wasm module.
  Stable since Dart 3.14.
- **wasm_tools** (simolus3). The shaper.
  A package on pub.dev; its source lives at simolus3/wasm.dart.
  It wraps a core module into a component with typed interfaces.
- **simolus3/wasm.dart**. The upstream repo itself.
  It hosts wasm_tools and the component tooling our work builds on.

## Our pieces

- A **vendored copy of wasm_tools 0.1.1-preview.1** in our fork (nmfisher/wasm.dart, `pkg/wasm_tools`).
  It carries exactly two patches:
  - The SIMD opcode table in the vendored wasm_builder grows from 256 to 280 entries.
    dart2wasm emits newer SIMD instructions; the old table failed to parse them.
  - The compiler transform tolerates a missing timeline report import.
    The stable SDK removes that import when a program does not use it; the old code required it.
- **tina-wasm-host**, our Rust host.
  It embeds wasmtime and runs the engine component inside it.
  It loads plugins, one Store per plugin.
  It checks ABI stamps before loading.
  It enforces capabilities on every host import.
- **Tina itself**, the product.
  A Dart agent engine, compiled into a component that lives inside the host.

## The flow

1. Tina is written in Dart.
2. dart2wasm compiles it to a core wasm module.
3. wasm_tools shapes the module into a component.
4. The component is embedded in tina-wasm-host.
5. At runtime, wasmtime executes it under the sandbox.
6. Plugins repeat the same loop at small scale.
7. Each plugin lands in its own private Store, gated by grants.

## Who owns what

- Google compiles.
- simolus3 shapes.
- wasmtime runs.
- Our host jails.
- Tina lives inside.

## Current pins

- Dart SDK 3.14.0, stable channel.
  The pin moved off the edge SDK; the edge build stays as a fallback.
- wasmtime 47.x (47.0.2 in the workspace `Cargo.toml`).
- wasm_tools 0.1.1-preview.1, vendored and patched in our fork.

## Where to read more

- `docs/tui-wasm-options.md` - the TUI-under-wasm options and the shape that landed.
- `docs/plugin_boundary.md` - the plugin boundary contract; it lives in the wasm.dart fork, not here.
- `docs/plugin-registry-design.md` - the plugin registry: publishing, serving, mounting.
- `docs/engine2-capability-merger.md` - how the host merges capability sources into one validated document.
- Issue #85 (nmfisher/tina) - the tracker for this workstream.
- nmfisher/wasm.dart, branch `codex/issue85-upstream-rebase` - the fork line: patched wasm_tools, the Rust host, the fixtures.

## Upstream candidates

The two wasm_tools patches are small and general.
Both are candidates to contribute upstream to simolus3/wasm.dart.
Until that lands, they stay as vendored patches.
