# No-wasmtime alternatives: plugins in plain Dart?

Proposal-only analysis. No code changed. Branch
`codex/issue85-no-wasmtime-alternatives` (off `codex/issue85-plugin-registry`
@ `18d210d1`). Question: what would the full plugin story — authoring,
runtime compilation, loading, use, unloading, replacement, capability
enforcement, sandboxing — take in plain Dart with no wasmtime?

## 1. Dynamic compilation

Dart has three ways to get new code into a running program. None is a
shippable plugin mechanism for an AOT product.

- **AOT binaries cannot compile new Dart.** There is no embedder API and
  no runtime compiler. `dartaotruntime` executes precompiled snapshots.
- **`Isolate.spawnUri`** can load source or kernel (.dill) files — but
  only under a JIT VM (`dart` itself). Shipping it means shipping the JIT
  VM inside the product and paying JIT warmup on every plugin boot.
- **VM-service hot reload** is a development tool. It needs the service
  protocol connection, does not exist in AOT, and was never a deploy
  story. **C dylibs via `dart:ffi`** load at runtime, but that is a
  C/Rust toolchain, not Dart, and `DynamicLibrary` has no unload.

So plugins must arrive precompiled. This was the original reason for the
wasm choice: a precompiled, portable, sandboxed unit. The registry leans
on exactly that — one wasm artifact per plugin-version, no per-platform
builds (`docs/plugin-registry-design.md`).

## 2. Isolation

Isolates are separate heaps inside one process. That is all they are.

- No address-space boundary and no permission boundary. Anything with
  FFI in-process can reach every heap. `dart:io` is process-global:
  filesystem and network cannot be granted per isolate, so the
  per-plugin consent model (file grants, the HTTP approval gate,
  `session.read-context`) has nothing to attach to.
- Uncaught Dart errors stay in their isolate. Native faults do not. An
  FFI bug, a VM bug, or `kill -9` ends the whole process, including the
  open sqlite session store.
- We have recorded the shape of that event. `tina_sqlite` treats a crash
  mid-append as real: a truncated tail line is an error, never silently
  dropped rows. The recovery checks kill a writer's process group before
  COMMIT and verify atomic recovery
  (`docs/persistence-durability.md`, `packages/tina_sqlite/README.md`).
  Native SIGSEGV hunts with the TUI are preserved in `tool/crash_hunt.sh`
  and `tool/crash_teardown.sh`.

## 3. Unload semantics

`Isolate.kill` is a true unload: the heap goes away. Two caveats.

- Kill takes effect at message checkpoints. A plugin spinning in a tight
  loop never reaches one. Dart has no preemption; only process death
  stops a runaway isolate.
- Short of killing the isolate, code loaded into a VM stays loaded. No
  module unload exists. Hot replacement means new code alongside old.

## 4. Process-per-plugin

One OS process per plugin, IPC to the engine. This is the pipes
architecture we already ship — the wasm engine runs the same
`SessionAssembly` over `runSessionPipes`, driven through stdio
(`packages/libraries/tina_wasm/bin/engine.dart`).

- Real isolation: separate address spaces; a crash ends one plugin
  process; the supervisor survives. Real enforcement gap: the OS grants
  nothing per plugin by default. The parent must mediate every file and
  network call over IPC, or drop OS privileges per child. That rebuilds,
  in Dart, what wasmtime's preopens and host imports already give us.
- Costs: one runtime boot per plugin, serialization on every call, and
  lifecycle plumbing per plugin.

## 5. What each side buys

Wasmtime today, each point in-tree:

- Runtime compilation of components: the host compiles the engine at
  boot and each plugin at load; `--plugin-watch` recompiles per attach
  (`pkg/tina_wasm_host/src/runner.rs`, wasm.dart).
- Memory isolation: the wasmtime sandbox.
- Capability enforcement: fail-closed policy document into WASI preopens
  (ro/rw), `tina:http` approvals, `tina:process` command patterns, and
  per-plugin grants (`policy.rs`, `tina_http.rs`, `tina_process.rs`).
- Epoch preemption: infinite-loop kills, tested for both plugins
  (`epoch_deadline_interrupts_spin_call_and_revokes_lease`, and lease
  revocation on the killed call) and the TUI (`TINA_TUI_EPOCH_TICKS`).
- Topology this enables: one async engine for the guest, a separate
  sync engine for plugins, one Store per plugin with lease/busy
  admission (`tina_plugin.rs`, `plugin_loader.rs`).
- One self-contained binary with engine and TUI embedded
  (`src/main.rs`), and a stable-SDK toolchain (dart2wasm on 3.14.0).
- Already-paid costs, honestly: the dart:io/dart:ffi closure had to be
  ported out of the front end; boot pays the JIT-compile tax (the ~19 s
  startup, under fix); `Finalizer`, `WeakReference`, `Expando` and real
  stack traces are stubs under Wasm GC, and raw dart2wasm interop is
  externref-only — the WIT component layer is what makes host/guest
  values typed (`docs/proposals/wasm_ecosystem_research.md`).

Plain Dart buys: no Rust toolchain or wasmtime in the product build,
native speed, no boot compile tax, the whole codebase unported, and
ordinary Dart debugging.

## 6. Decision matrix

Status quo = today's native binary with every plugin compiled in
(pre-#85). ✔ yes, ~ partial, ✘ no.

| | wasmtime stack | plain-Dart isolates | process-per-plugin | status quo |
|---|---|---|---|---|
| Compile new code at runtime | ✔ (wasm) | ✘ (AOT) or ship JIT VM | ✘ same, or ship JIT VM | ✘ |
| Unload / kill runaway plugin | ✔ epoch | ~ kill at checkpoints; no preemption | ✔ process kill | n/a |
| Per-plugin capability grant | ✔ preopens + policy | ✘ dart:io is process-global | ~ supervisor-mediated | n/a |
| Crash containment | ✔ sandbox | ✘ one process, store inside | ✔ per process | one process |
| Hot replace | ✔ watch mode + new Store | ~ shadow code, no unload | ✔ spawn new process | ✘ |
| Performance | JIT-compiled wasm; boot tax | native | native + IPC per call | native |
| Deployment | one binary + wasm artifacts | one binary | engine + per-plugin runtimes | one binary |

## 7. Recommendation

Keep wasmtime. Plain Dart cannot enforce capabilities or contain native
faults, and the consent model dies with them. If wasmtime must go,
process-per-plugin is the only honest fallback — it is the pipes
architecture, costs IPC latency and a supervisor we would have to write,
and still ships precompiled plugins. Isolates alone are not a plugin
story; they are a concurrency story.
