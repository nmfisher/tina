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

Implement external WASM tools as a restricted tier alongside trusted built-in
Dart plugins. The phased plan is
[WASM plugin support](../docs/proposals/wasm_plugin_support.md).

The implementation baseline is main at `43e60e1` (v0.6.13), including merged
PR #49. This ticket and PR #52 contain documentation only. Implementation phases
remain unchecked until their exit gates have evidence.

Phase 0 status: pinned packaging, the supervised worker, native ABI calls, and
epoch-driven cancellation are proven **on Linux x64 only** (results and
measurements in
[phase 0 results](../docs/proposals/wasm_plugin_support_phase0_results.md));
macOS ARM64 and Linux ARM64 are packaged and checksummed but unverified, so
the box below stays unchecked until those targets have native evidence.

## Phases

- [ ] 0: Prove pinned Wasmtime packaging and supervised worker cancellation on
  macOS ARM64, Linux x64, and Linux ARM64; record limits and measurements.
- [ ] 1: Validate manifests/module bytes before activation; implement the exact
  core WASM ABI with native malformed-input fixtures.
- [ ] 2: Add async factories, owned workers, joined cancellation, and rollback.
- [ ] 3: Run one pure JSON transformation tool through the real agent path,
  permissions, nested conversations, and restoration.
- [ ] 4: Package and test headless/TUI/installer support on all three targets.
  Phases 0–4 together define the first supported release.
- [ ] 5: Add narrow, revocable host operations with live policy checks.
- [ ] 6: Add asynchronous guards, then result hooks and bounded observers.

## Required constraints

- Native guest execution runs in a supervised worker process, never on the
  agent/UI isolate. Cancellation and teardown join all owned work.
- Explicitly configured plugins fail closed when unavailable; a missing guard
  must never silently disappear.
- API 1 has one pure tool per module, bounded logging/configuration, and no WASI,
  filesystem, network, arbitrary services, or hooks. Keep `write_summary` in Dart.
- Mode changes enforce live policy without remounting plugins or changing the
  model's cached tool declarations. Later capabilities are brokered per operation,
  never granted permanently through mount-time filesystem preopens.
- Native Wasmtime tests are required; mock or interpreter tests cannot replace
  packaging, ABI, cancellation, and lifecycle verification.

## Links

- [Implementation plan and exit gates](../docs/proposals/wasm_plugin_support.md)
- [Original plugin runtime plan](../docs/proposals/plugin_runtime.md)
- [PR #49 review fixes](../docs/proposals/plugin_runtime_pr49_fixes.md)
- PR #49: merged plugin runtime; PR #52: this proposal.
