# No-wasmtime alternatives: a 100% Dart plugin story?

Proposal-only analysis. No code changed. Branch
`codex/issue85-no-wasmtime-alternatives` (off `codex/issue85-plugin-registry`
@ `18d210d1`). Constraint (Nick): zero wasmtime anywhere — not embedded,
not via FFI. Wasmtime-embedding options are treated below only as
rejected alternatives. Question: what does a pure-Dart plugin story look
like, and what does the product lose versus the current wasm stack?

## 1. The pure-Dart baseline: PR #49 today

PR #49 (merged in main at `43e60e1`, v0.6.13) built the plugin runtime:
typed services (`ServiceKey`), scopes with reversible registrations,
validation before activation, deterministic ordering, rollback on
failure, child-before-parent teardown. Extensions ride the same scope —
tools, deny-only guards, execution/result hooks, observers. Documented as
implemented in `docs/plugin_system.md` (branch `wasm-plugin-support`).

What it deliberately lacks, in that document's own words: "no loader, no
external plugins … adding one means recompiling"; no user-facing plugin
config; no async factories. The trust model is compiled-in: services are
Dart objects, "not a security boundary"
(`docs/proposals/wasm_plugin_support.md` §2). Versus the wasm stack it
lacks exactly: runtime compilation of new code, memory isolation,
per-plugin capability enforcement, crash containment, and unload
guarantees for external code.

## 2. The extension paths, head-on

- **`Isolate.spawnUri` + shipped JIT VM.** Loads Dart source/kernel at
  runtime — the only true dynamic-compile path, and it requires shipping
  the JIT VM inside an AOT product. Lost versus wasm: the AOT binary,
  warmup predictability, and still no isolation — isolates share one
  process, `dart:io` is all-or-nothing, so consent grants cannot attach;
  a native fault or `kill -9` takes the process including the sqlite
  store (the truncated-tail and kill-before-COMMIT recovery rules in
  `packages/tina_sqlite` and `docs/persistence-durability.md` exist for
  that hazard).
- **Dev-mode-only paths (VM-service hot reload).** Dev tooling; needs
  the service protocol; does not exist in AOT. Not shippable.
- **Accept no runtime compilation; prebuilt plugin artifacts.** An AOT
  binary can only run code it was built with — there is no embedder API
  to load new Dart. "Prebuilt" pure-Dart plugins therefore mean separate
  processes, which is §4 — everything else collapses back to compiled-in.
- **No preemption either way.** `Isolate.kill` lands at message
  checkpoints; a spinning plugin isolate cannot be stopped, only the
  process can. Unload of loaded code otherwise does not exist.

## 3. What the wasm stack (rejected here) had bought

For comparison only — this is what a pure-Dart story must replace:
runtime compilation of components at boot and per plugin load; the
wasmtime sandbox; fail-closed capability documents into WASI preopens,
`tina:http` approvals, `tina:process` patterns; epoch kills, tested
(`epoch_deadline_interrupts_spin_call_and_revokes_lease`); one Store per
plugin with lease/busy admission; one self-contained binary; one signed,
portable artifact per plugin-version in the registry.

## 4. Process-per-plugin: the honest pure-Dart fallback

One OS process per plugin, IPC to the engine — the pipes architecture we
already ship (`packages/libraries/tina_wasm/bin/engine.dart` runs the
same `SessionAssembly` over `runSessionPipes`). Real isolation: separate
address spaces; a crash ends one plugin process. But the OS grants
nothing per plugin by default: the supervisor must mediate every file
and network call over IPC, or drop privileges per child — rebuilding in
Dart what preopens and host imports gave. Costs: a runtime boot per
plugin, serialization on every call, lifecycle plumbing. This path also
carries the store-vs-plugin split naturally: the engine process owns
sqlite; plugins never touch it.

## 5. Rejected: every wasmtime embedding

- **PR #52 tin-w4sm FFI** (`packages/dart_wasmtime`, wasm-plugin-support
  line): vendored wasmtime v36 static archives per target, `@Native`
  bindings, a supervised worker isolate, epoch interruption. Rejected:
  it contains wasmtime — the constraint forbids it outright. It also
  carried per-platform vendored archives (a 25.2 MB merged lib) and the
  dart2wasm interop limits that later pushed us to the component model:
  externref-only host sharing and stubbed `Finalizer`/`WeakReference`/
  `Expando`/stack traces (`docs/proposals/wasm_ecosystem_research.md`).
- **The current Rust host** (`tina-wasm-host` in wasm.dart): rejected by
  the same constraint, though it is what main's engine leg uses today;
  its capabilities are the baseline every variant above is measured
  against.

## 6. Decision matrix

✔ yes, ~ partial, ✘ no. "PR #49 ext." = pure-Dart isolates extended.

| | wasm stack (rejected) | PR #49 ext. | process-per-plugin | PR #52 FFI (rejected) | hot reload (rejected) |
|---|---|---|---|---|---|
| New code without recompile | ✔ | ~ JIT VM only | ~ child programs | ✔ | ✔ dev only |
| Zero wasmtime | ✘ | ✔ | ✔ | ✘ | ✔ |
| Per-plugin capability grant | ✔ | ✘ process-global | ~ supervisor | ✔ | ✘ |
| Crash containment | ✔ | ✘ store inside | ✔ | ✔ | ✘ |
| Kill runaway plugin | ✔ epoch | ✘ no preemption | ✔ | ✔ | ✘ |
| Unload / hot replace | ✔ | ~ checkpoints | ✔ | ~ | ✔ dev only |
| Performance | wasm + boot tax | native | native + IPC | native-side FFI | native |
| Ship as one binary | ✔ | ✔ | engine + children | ✔ + vendored libs | ✘ |

## 7. Recommendation

Under a zero-wasmtime rule, the shippable pure-Dart story is PR #49 for
trusted, compiled-in plugins plus process-per-plugin for anything
external. In-process isolate loading (spawnUri) should stay out: it
costs the AOT product and buys no enforcement. The product loses, versus
the wasm stack, runtime compilation, sandboxed consent enforcement and
crash containment in-process; a written supervisor owns them instead.
