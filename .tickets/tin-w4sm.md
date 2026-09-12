---
id: tin-w4sm
status: open
deps: []
links: [pr-49, tin-9zqx]
created: 2026-09-12T00:00:00Z
type: proposal
priority: 3
assignee: Nick Fisher
tags: [plugins, wasm, runtime, proposal]
---

# WASM plugin support

## Summary

Review the plugin runtime as built (PR #49, branch `asb/plugin-runtime`), then
propose how plugins could be WebAssembly modules instead of in-process Dart.

The proposal is written: `docs/proposals/wasm_plugin_support.md`.

Part 1 (review) finds: plugins are synchronous `PluginDescriptor` factories
over `ServiceKey`/`PluginScope`; everything an agent layer consumes arrives as
scope contributions filtered by `is` checks (tools, guards, execution/result
hooks, observers); the trust model is "compiled into the binary" — no
isolation beyond deny-preserving guards and exactly-once hook delegation.
Loading a plugin from outside the binary is blocked by (a) AOT compilation
and (b) an unconfined capability surface — the two things WASM directly
addresses.

Part 2 (design) recommends: wasmtime via FFI (cdylibs pre-staged per target
like the existing notcurses libs), a manifest + module contract (JSON over
linear memory, `tina_abi_version`/`tina_config`/`tina_start`/`tina_stop`
lifecycle mapped one-to-one onto `PluginRuntime`'s existing
validate → activate → rollback → dispose path), tools/guards/result
hooks/observers crossing the boundary, drivers staying host-side, and
capabilities mapped onto `PermissionPolicy` and the mode boundary so a module
can never smuggle past `readAll`. Smallest first step: an
`AsyncPluginFactory` seam plus a one-tool loader, with the write-summary
sidecar tool as the first conversion.

## Links

- PR #49 — plugin runtime (branch `asb/plugin-runtime`)
- `docs/proposals/plugin_runtime.md`
- `docs/proposals/plugin_runtime_pr49_fixes.md`
- `docs/proposals/wasm_plugin_support.md` (this proposal)
