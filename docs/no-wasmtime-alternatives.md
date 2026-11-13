# No-wasmtime alternatives: a 100% Dart plugin story

Proposal-only analysis. No code changed. Branch
`codex/issue85-no-wasmtime-alternatives` (off `codex/issue85-plugin-registry`
@ `18d210d1`). Constraint (Nick): zero wasmtime anywhere, not even FFI.
Amendment 2 retraction: pure Dart CAN deliver live authoring-compile-load
with isolation, via SDK patches — and this program already source-builds
the SDK, so patch maintenance rides existing infrastructure.

## 1. The pure-Dart baseline: PR #49 today

PR #49 (merged in main at `43e60e1`, v0.6.13) built the plugin runtime:
typed services, scopes with reversible registrations, validation,
rollback, teardown; tools, guards, hooks and observers ride the same
scope. Per `docs/plugin_system.md` (branch `wasm-plugin-support`):
"no loader, no external plugins … adding one means recompiling"; no
user-facing config; no async factories; services are Dart objects,
"not a security boundary" (`docs/proposals/wasm_plugin_support.md` §2).
Gaps versus the wasm stack: runtime compilation, memory isolation,
per-plugin capability enforcement, crash containment, unload guarantees.

## 2. The first-class route: 100% Dart + SDK patches

Three patches; sizes are estimated lines of SDK surface touched.

**P1 — Runtime kernel loading.** `package:front_end` compiles Dart
source to kernel (.dill) in-process — pure Dart, ships in the SDK, zero
patch. Missing is loading fresh kernel into a running product; the
mechanism exists (`Isolate.spawnUri` loads .dill on the JIT VM; the VM
service injects kernel for hot reload via `reloadSources`), gated to
dev mode. Patch options:

- **P1a, spawn-from-kernel-bytes API**: kernel bytes instead of a URI at
  the embedder/Isolate boundary. Small — hundreds of lines near the
  existing dill reader and `dart_api.h`. Upstreamable: plausible, it
  mirrors an existing path. Per-upgrade: small (surface-level).
- **P1b, un-gate reload injection for products**: moderate — an API
  decision around existing service machinery. Upstreamability unclear.
- **P1c, hybrid AOT+JIT runtime** (kernel loader linked into
  `dartaotruntime`): large — thousands of lines plus build config; the
  VM deliberately splits compiler from AOT. Low upstreamability. P1a on
  a JIT-VM product is the realistic default; P1c only if AOT is hard.

**P2 — Per-isolate IO capability enforcement.** dart:io is all-or-nothing
per process today. Patch: a capability token granted at isolate spawn,
checked at the dart:io choke points — file, directory, socket, HTTP,
process natives (`runtime/bin` already funnels through `_Namespace`-
style scoping; the isolate API has historical capability semantics).
Estimate 1–3 kLOC across `runtime/bin`, `sdk/lib/io`, the spawn API.
Upstreamable: plausible as opt-in (default grant = today's behavior).
Per-upgrade: moderate merge friction, stable area.

**P3 — Preemption.** `Isolate.kill` is already true unload: the heap is
reclaimed. Missing is reaching a runaway isolate: kill lands at message
checkpoints, and a tight loop starves them. The VM already stops
isolates at GC safepoints inside loops and services debug interrupts —
the machinery exists. Patch: honor kill/deadline at those safepoints.
Small-to-moderate, in `runtime/vm` interrupt handling. Upstreamable:
plausible, arguably a robustness fix. Per-upgrade: small.

**Maintenance.** SDK patches are real work with a per-upgrade rebase
cost, but the program already pays that kind of cost: the SDK is
source-built and pinned (edge gclient checkout + `tools/build.py
create_sdk` recipe in wasm.dart `docs/stage0_pinning.md`; stable 3.14.0
via `/home/agent/tools/build_pinned_sdk.sh`) and vendored toolchain
patches are already carried (wasm_tools SIMD table, timeline-import
tolerance). A patch set is a new row in that table, not new
infrastructure.

## 3. What the patches honestly do not give

- In-process memory isolation: isolates stay in one address space. P2+P3
  contain pure-Dart misbehavior, but FFI in the process can reach every
  heap, and a native fault kills the process including the sqlite store
  (the hazard the truncated-tail and kill-before-COMMIT recovery rules
  in `packages/tina_sqlite` exist for).
- Preemption stops at native calls: a plugin inside FFI cannot be
  interrupted. Hostile or native-touching plugins still need §4.
- Plugin code runs JIT-compiled (P1): warmup, no AOT speed — precompiled
  plugins instead collapse back to compiled-in.

## 4. Process-per-plugin: the fallback for untrusted code

One OS process per plugin, IPC to the engine — the pipes architecture
already shipped (`engine.dart` runs the same `SessionAssembly` over
`runSessionPipes`). Real address-space isolation and crash containment;
the supervisor must mediate file and network calls or drop privileges
per child, and every call pays IPC.

## 5. Rejected: every wasmtime embedding

- **PR #52 tin-w4sm FFI** (`packages/dart_wasmtime`, wasm-plugin-support
  line): vendored wasmtime v36 static archives, `@Native` bindings, a
  supervised worker isolate. Rejected: it contains wasmtime. It also
  carried a 25.2 MB merged lib and the dart2wasm interop limits
  (externref-only sharing, stubbed `Finalizer`/`WeakReference`/`Expando`)
  noted in `docs/proposals/wasm_ecosystem_research.md`.
- **The current Rust host** (`tina-wasm-host` in wasm.dart): rejected by
  the same constraint; it stays main's engine leg and the comparison
  baseline (epoch kills, preopen policy, one Store per plugin, one
  binary).

## 6. Decision matrix

✔ yes, ~ partial, ✘ no. "SDK-patched" = P1a + P2 + P3 on a JIT-VM product.

| | wasm stack (rejected) | SDK-patched Dart | isolates unpatched | process-per-plugin | FFI (rejected) |
|---|---|---|---|---|---|
| Live compile-load | ✔ | ✔ P1 | ~ JIT VM, no gates | ~ child programs | ✔ |
| Per-plugin capability grant | ✔ | ✔ P2 | ✘ process-global | ~ supervisor | ✔ |
| Kill runaway plugin | ✔ epoch | ✔ P3 (Dart loops) | ✘ no preemption | ✔ | ✔ |
| Unload / hot replace | ✔ | ✔ kill + reload | ~ checkpoints only | ✔ | ~ |
| In-process isolation (fault + memory) | ✔ | ✘ one address space | ✘ | ✔ | ✔ |
| Performance | wasm, boot JIT tax | native, plugin JIT warmup | native | native + IPC | FFI edge |
| Deployment | one binary | patched-SDK build (infra exists) | one binary | engine + children | vendored libs |

## 7. Recommendation

The SDK-patch route is feasible and first-class: P1a + P2 + P3 is on the
order of 2–4 kLOC of SDK surface, riding the source-build infrastructure
this program already runs. It delivers live authoring-compile-load,
per-plugin consent enforcement, preemption and true unload for
pure-Dart, FFI-free plugins. Honest residuals: no in-process memory
isolation or native-fault containment, plugin JIT warmup, and a
per-upgrade patch-rebase line item. Hostile or native-touching code
goes to process-per-plugin. That is the strongest pure-Dart story under
a zero-wasmtime rule.
