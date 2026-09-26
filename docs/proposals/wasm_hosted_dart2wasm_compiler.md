# Research: a wasm-hosted dart2wasm compiler as a tina plugin

Status: research summary; no implementation has started.
Date: 2026-09-28.
Anchors: `main` @ `72a5521` (`asb/engine2`); external facts verified live this
session (wasmtime releases API, dart-lang/sdk repo contents, dart-live README
and repo listing, minidart.run page; later the GitHub compare API for the
patch fork, upstream `pkg/dart2wasm` sources, wasmtime issue #1641, the
v8.dev Emscripten-standalone writeup, and Emscripten docs). The five open
questions at the end of the first draft are answered in the closing section.
Sizes and latency figures marked *estimate* are not measured; Q4 notes the
one flag spelling that was not confirmed this session.

## The question

Can tina ship **dart2wasm compiled to wasm** — a compiler-as-data — so that
tina's host can compile agent-authored plugins itself: the agent writes Dart,
the shipped compiler (running inside tina's own wasmtime loader) emits
`plugin.wasm`, and the same loader instantiates the result. One substrate
end to end: wasm compiles wasm, wasm runs the result, no native toolchain on
the user's machine.

## Prior conclusions in this repository

This session started from the existing analysis and re-examined it:

- [`tina-wasm-proposal.md`](../tina-wasm-proposal.md) Part 1 names four
  blockers for external plugins: (1) no loader for new code in an AOT binary,
  (2) synchronous plugin factories, (3) no capability firewall for in-process
  code, (4) no manifest/distribution/trust story. Part 2 designs the wasm
  plugin tier: `plugin.json` + `plugin.wasm`, wasmtime via FFI, capability
  imports, fuel/epoch limits, JSON-over-linear-memory ABI.
  Its open question 2 — "does dart2wasm output run under wasmtime well enough
  that a *Dart-authored* plugin can target this pipeline?" — is this
  document's subject. Its open question for a *compiler* module had no prior
  research; that gap is filled below.
- [`packages/plugins/README.md`](../../packages/plugins/README.md): config
  selects linked factories; the `tina/` namespace rule is "a naming rule for
  trusted plugins, not a sandbox for arbitrary Dart code."
- [`spikes/dart_wasm_worker`](../../spikes/dart_wasm_worker): dart2wasm output
  runs under workerd; runtime wasm compilation is banned *by workerd only* —
  wasmtime's job is runtime compilation, so that finding does not apply to a
  wasmtime-based loader.
- An earlier pass concluded "a wasm-compiled dart2wasm is a compiler project /
  the CFE must be ported." The external evidence below shows that conclusion
  was too pessimistic: the hard parts have working precedents.

## What exists outside (verified 2026-09-28)

### dart-live — the decisive prior art

[`modulovalue/dart-live`](https://github.com/modulovalue/dart-live), shown on
Hacker News 2026-05-13. "The Dart VM, compiled to WebAssembly, running in your
browser, with stateful hot reload." Single-page app, GitHub Pages, no server.

| artifact | size | role |
|---|---:|---|
| `dart_cfe.wasm` | 2.4 MB | **The Common Front End compiled to wasm** — compiles Dart source to kernel in-page |
| `dart_lsp.wasm` | 4.4 MB | **The full Dart analysis server compiled to wasm**, speaking LSP over a JS bridge |
| `dart_il.wasm` | 18 MB | The Dart VM (emcc) executing kernel via the VM's built-in ARM interpreter; enables stateful hot reload |
| `vm_platform.dill` | 8.3 MB | Platform kernel (`dart:core`, …) shipped as data |
| `dart_sdk.sum` + `dart_packages.bin` | 4.1 MB | Analyzer summary + default external-package source bundle |

Total ~29 MB uncompressed, ~8 MB gzipped. What this proves:

1. **The CFE runs outside the Dart VM**, compiled to wasm, at 2.4 MB. The
   frontend of the proposed compiler exists.
2. **Heavyweight pure-Dart tooling compiles to wasm** — the analysis server is
   the existence proof. The dart2wasm backend + `pkg/wasm_builder` (verified:
   pure library — no `bin/`, no native deps) are comparable pure-Dart shapes.
3. **Source feeding into a wasm-hosted compiler is solved and documented**:
   dart-live's DPKG bundle format (trivial little-endian blob) is mounted into
   an in-memory `MemoryResourceProvider`; platform libraries and packages are
   bundled as data dills/source.

What it does **not** prove:

- **No kernel→WasmGC backend compiled to wasm.** dart-live sidesteps it: CFE
  produces kernel, the *VM interpreter* executes it. Nothing ever emits
  `plugin.wasm`. That backend compiled to wasm is still missing.
- **The modules are Emscripten-bound.** They ship `.mjs` glue and use
  `EM_ASM`/Asyncify; they expect a JS host. They do not drop into wasmtime
  unmodified — but see Q1 below: the supported fix is a standalone-mode
  rebuild, not a shim.
- Single-maintainer project; freshness and upkeep unknown. The patch
  availability concern is **resolved**: the SDK patches were published on
  2026-05-23 as branch `dart-live` of
  [`modulovalue/sdk`](https://github.com/modulovalue/sdk) — one squashed
  commit (`f061b6a`) off an Apr 27 2026 merge base, currently 2,807 commits
  behind `main` (details in Q2 below).

### Others

- [`minidart.run`](https://minidart.run): **not applicable** — a from-scratch
  Dart frontend in C sharing the "kavak" kernel; explicitly has no compiler
  yet ("awaiting kavak Phase 1").
- wasmtime: v49.0.1 released 2026-09-24; GC mature; releases themselves ship
  precompiled WASI command modules.
- `pkg/dart2wasm` on SDK `main`: backend (`lib/`), driver (`bin/`), docs;
  **no self-hosted wasm artifact ships with the SDK**.

### The upstream standalone track — found late, it changes the minimum

[dart-lang/sdk#53884](https://github.com/dart-lang/sdk/issues/53884)
("[dart2wasm] Support non-JS wasm runtimes", open since 2023, still active —
last touched 2026-08) has produced a working pipeline that did not exist when
this document was first written:

- `simolus3` built a **standalone dart2wasm target** — a `dart2wasm`
  platform whose `dart:*` libraries use **documented host imports** instead
  of JS (`sdk/lib/_internal/wasm/standalone/embedder.dart`), now merged on
  SDK `main` behind the `--standalone` flag of `dart compile wasm` (visible
  in `compiler_options.dart`; the standalone platform dill ships with the
  SDK). This supersedes the CFE-shim discussion for *plugin output*: modules
  compiled with `--standalone` are wasmtime-native from birth — no
  Emscripten, no JS host, no shim.
- [`simolus3/wasm.dart`](https://github.com/simolus3/wasm.dart) is the
  companion project: "the goal is to get `wasmtime run
  dart_compiled_app.wasm` to work without further setup." It (a) implements
  the embedder host imports **in Dart compiled to wasm**, linked
  post-compilation so modules become self-contained (`@pragma('wasm:export')`
  + a link step), (b) provides `wasm_tools` (Dart → WebAssembly **components**
  with wit bindings) and `wasm_components` (a Dart component-model runtime),
  and (c) demos hello-world running under wasmtime from a Rust host. Its
  status table classifies every extern: most string ops and scheduling ✅;
  weak refs / expandos 🛑 — *fundamentally unavailable in wasm*, stubs only.
- The last named runtime blocker,
  [#54394](https://github.com/dart-lang/sdk/issues/54394) ("Use new exception
  instructions" — wasmtime rejects dart2wasm's legacy try/catch), is
  **closed**.
- SDK team engagement is real: `mkustermann` reviewed the approach (Jan/Feb
  2026, preferring a separate platform dill with different core-lib patches
  over migrating everything off `@JS()`), `kevmoo` summarized the plan into
  the issue and reports LLM-generated host-import implementations working,
  and `justinfagnani` (Aug 2026) proposed a shared Rust crate for the
  imports.

Consequence for this document: the **plugin substrate** (run agent-authored
Dart under wasmtime) is upstream work at demo quality today; what remains
missing is only the **compiler itself compiled to wasm** — the original
question — for which dart-live remains the decisive prior art.

## Gap analysis for tina's use case

| piece | status |
|---|---|
| Wasm plugin loader in tina | designed (`tina-wasm-proposal.md` §3–§6), not implemented |
| `AsyncPluginFactory` seam | designed (§7 step 1), not implemented |
| Dart source → kernel, wasm-hosted | **exists** (dart-live `dart_cfe.wasm`) |
| Dart module running under wasmtime (plugin substrate) | **upstream, demo quality** — `--standalone` on SDK `main` + `wasm.dart` externs; weak refs unavailable |
| wasmtime runtime blocker for dart2wasm output | **closed** (#54394, new exception instructions) |
| Kernel → WasmGC backend, wasm-hosted (the compiler itself) | missing — the actual remaining gap |
| Emscripten → wasmtime: standalone-mode rebuild | answered — supported path; no shim possible (wasmtime refuses Emscripten ABI); largely mooted for plugin output by `--standalone` |
| SDK patches for wasm-clean CFE | **published** — `modulovalue/sdk` branch `dart-live`, one commit |
| Plugin manifest/digest/trust handling | designed (§3), not implemented |

## The architecture, if built

`tina/dart2wasm` ships as an opt-in plugin (`[plugins].enabled`) contributing
a `compile_plugin` tool:

```
agent writes .tina/plugins/<id>/src/*.dart
        │
        ▼
compile_plugin tool                        (PolicyToolGuard gates the call)
        │
        ▼
wasmtime Store, zero imports, fuel+epoch   ── runs  dart2wasm.command.wasm
        │   (Dart source in → plugin.wasm out)
        ▼
host parses wasm, builds manifest, digest  (tina-wasm-proposal §3)
        │
        ▼
user approves mount → AsyncPluginFactory → PolicyToolGuard per call
```

Properties worth keeping in any variant:

- **The compiler module's capability set is empty** — no fs, no net, no clock,
  no env. It is the most sandboxed process in the design; it cannot exfiltrate
  source, persist, or outlive an epoch deadline. Compile in a separate,
  strictly capped store; mount the result in the normal one.
- **Shrink-only failure mode:** the host (not the compiler) builds the
  manifest and digest from its own compile request. A compiler that lies in a
  manifest yields a plugin with fewer wired contributions than it exports.
- The compiler does not strictly need PluginRuntime services at all (bare
  command module with no imports); mounting it as a plugin is a product choice
  so `/permissions` governs *when* compilation happens.
- Version pinning is a quartet: dart2wasm ↔ plugin `api` ↔ wasmtime ↔
  OS/arch. Package per-target **precompiled** command modules via the
  notcurses `release.yml` pre-staging pattern, or lazy-fetch with a pinned
  digest to keep tarballs slim.

## Sequencing recommendation (rewritten after finding the upstream track)

Two tracks, different clocks.

**Track A — plugin substrate (agent Dart runs under wasmtime). No longer
tina work; ride upstream.**

1. tina still needs its own seam: `AsyncPluginFactory` + wasm plugin loading
   + manifest/digest validation (`tina-wasm-proposal.md` §7 steps 1–3).
2. Accept `--standalone` dart2wasm modules as the plugin format. Compile
   authoring output with the user's local SDK if present (or a
   checksum-pinned SDK download), link `wasm.dart`'s Dart-side extern
   definitions per its recipes, and require: no weak-ref/expando use
   (unavailable), no fs/net/env imports beyond what the mount grants.
3. Follow `simolus3/wasm.dart` toward components (`wasm_tools`) — a component
   manifest with typed interfaces is a better trust anchor for §3 than raw
   core modules.

**Track B — the compiler itself compiled to wasm (this document's original
question). Still missing; dart-live is the prior art.**

1. Rebuild the substrate decision on `--standalone`: the compiler module
   should itself be a standalone dart2wasm module — capability-free, running
   in its own fuel/epoch-capped store.
2. Compile `pkg/dart2wasm`'s backend + `wasm_builder` (+ the CFE) with
   `--standalone`, using dart-live's patches as the map for the CFE-side
   work (in-memory FileSystem feeding, platform dill as data) and Q3's
   finding that the layering already supports it. Skip wasm-opt (Q4).
3. Open question that remains genuinely open: can the CFE's embedder needs
   (timers for progress, weak refs inside the compiler's own heaps — see the
   🛑 rows) be satisfied or stubbed for a *compiler* workload? dart-live
   ran the CFE under the JS-embedder VM, so this specific crossing has no
   public proof yet.
4. Until B lands, Track A's authoring loop uses a native dart2wasm (local
   SDK or pinned download) — the recursion is an optimization, not a
   prerequisite.

## Open questions, answered (2026-09-28)

### Q1: Can dart-live's Emscripten modules run under wasmtime, or is a rewrite needed?

**No shim — but no rewrite either. The bridge exists and is a supported
path: recompile with Emscripten's standalone mode.**

- Wasmtime **explicitly refuses the Emscripten ABI**:
  [wasmtime#1641](https://github.com/bytecodealliance/wasmtime/issues/1641) —
  "We explicitly decided not to support the Emscripten ABI in Wasmtime," with
  the WASI announcement post cited as the reason (Emscripten's ABI embeds
  `EM_ASM` JS snippets; WASI keeps capability grants structural). A
  JS-shim-over-wasmtime for the existing binaries is therefore off the table
  by upstream policy.
- Emscripten ships **standalone mode** (`-sSTANDALONE_WASM`), "intended for
  building applications to run in WASM runtimes without JavaScript," using
  WASI where possible — see the
  [v8.dev writeup](https://v8.dev/blog/emscripten-standalone-wasm) and the
  [current Emscripten docs](https://emscripten.org/docs/compiling/WebAssembly.html).
  Known costs: larger binaries, and anything WASI cannot express becomes a
  custom import.
- The dart-live patch set already contains the GN toolchain plumbing
  (`emcc_toolchain.gni`, `wasm/BUILD.gn`, per the `f061b6a` commit message),
  so the retarget is adding standalone flags to an existing build target.
- Residual irreducibles: Asyncify (`emscripten_sleep` powering
  `Future.delayed`) has no WASI equivalent — but a compile-to-completion
  command module does not need it; and the two custom natives
  (`EmbedderJSEval`, `InvokeRpcSync`) belong to the runtime module, not the
  compiler.
- Postscript: for *plugin output* this whole question is now largely mooted —
  upstream's `--standalone` target (see the §53884 section) produces
  wasmtime-native modules without Emscripten at all. The rebuild path
  matters only for reusing dart-live's own modules (e.g. `dart_cfe.wasm` in
  a wasmtime-hosted compiler).

### Q2: Are the SDK patches obtainable, and do they conflict with `main`?

**Yes — fully published as of 2026-05-23, and they are one squashed commit.**

[`modulovalue/sdk`](https://github.com/modulovalue/sdk), branch **`dart-live`**,
commit `f061b6a` ("dart-live: SDK patches for in-browser Dart VM + CFE +
analyzer"), authored 2026-05-23. The branch is **ahead by 6, behind by 2,807**
vs `dart-lang:main` (GitHub compare API, checked 2026-09-28; merge base
2026-04-27). Five of the six commits are unrelated bit-twiddling experiments
(`trailingZeroBitCount`/`oneBitCount` work toward SDK issues #6486/#1053),
leaving **exactly one patch commit to review**. Its message enumerates the set:

- `pkg/{cfe_web,cfe_wrapper,analyzer_web}.dart`: **dart2wasm-targeted**
  wrappers exposing `dartCompile` / `dartAnalyzerInit` / `dartAnalyze`;
  the CFE wrapper takes additional dills, the analyzer takes package summary
  bundles via parallel arrays.
- `sdk/lib/_internal/vm/lib/{js_helper,js_types,js_interop_patch,
  js_interop_unsafe_patch,js_util_patch,foreign_helper}.dart`: VM-side
  `dart:js_interop` / `dart:js_interop_unsafe` surface, JSValue handle table,
  `promiseToDartFuture`, Dart-callback registry.
- `pkg/vm/lib/modular/target/vm.dart`: wires SharedInteropTransformer +
  JsUtilOptimizer + StaticInteropClassEraser into the VM target.
- `sdk/lib/libraries.{yaml,json}`: registers the new VM patch libraries.
- `runtime/vm/service.{h,cc}`: `Service::InvokeRpcSync` for the in-process
  VM Service Protocol.
- `build/toolchain/{emcc_toolchain.gni,wasm/BUILD.gn}` + BUILDCONFIG.gn +
  toolchain_suite.gni + runtime/BUILD.gn: the emscripten + wasm-sim build
  targets.
- Various `runtime/vm/*.cc` edits (bootstrap_natives, os_*, dart.cc,
  virtual_memory_posix, simulator_arm, …): small fixes to build and
  initialize the VM under emscripten/wasm-sim.

Two facts fall out: (a) nothing in the set is a kernel/CFE rewrite — it is
wrappers, build plumbing, and VM embedder fixes; (b) being 2,807 commits
behind makes rebasing a real but bounded task. A one-shot
`dart-lang:main...modulovalue:dart-live.diff` URL exists for review.

### Q3: Is the dart2wasm backend clean pure-Dart?

**Yes at the layer that matters — and there is direct evidence it compiles
under dart2wasm's own target.**

- Upstream layering is already correct (checked on SDK `main` 2026-09-28):
  `pkg/dart2wasm/lib/compile.dart` imports `front_end`, `kernel`, `vm`,
  `wasm_builder`, `path`, `pool` — **no `dart:io`**. Filesystem/process
  access is quarantined in `io_util.dart` (`CompilerPhaseInputOutputManager`
  uses `File`/`Process` for wasm-opt and source-map output) and in the CLI
  driver (`bin/dart2wasm.dart` is a thin `exitCode = await dart2wasm.main()`
  shell; `generate_wasm.dart` hardcodes
  `StandardFileSystem.instance`). The `compile()` function **takes a
  `FileSystem` parameter** — the exact seam a wasm embedder needs. A
  `--dry-run` compiler phase already exists that reports inputs without
  touching the filesystem.
- Direct evidence: the `f061b6a` commit message describes the wrapper
  packages as "**dart2wasm-targeted**" — the author compiled CFE/analyzer
  wrapper code with dart2wasm itself and the resulting modules ship and run.
  "Dart in this part of the toolchain can be compiled by dart2wasm" is
  therefore demonstrated by a working artifact, not argued.
- Caveats kept honest: which dart2wasm feature set that build used is not
  recorded; the backend reaches io for wasm-opt and source maps (skippable
  paths). The engineering task is "wire `compile()` to a memory FileSystem
  and skip the io-util paths" — bounded, with precedent in hand.

### Q4: What fuel/epoch budget does a wasm-hosted plugin compile need?

**No published numbers exist; this stays a must-measure item, but the
measurement is now scoped and shaped.**

- The only in-the-wild datapoint is dart-live itself: the whole toolchain
  runs in a browser tab with in-page compilation and no server — the author
  evidently finds plugin-scale compiles tolerable there, but publishes no
  timings.
- Shape of the cost: the platform dill is loaded, not compiled (8.3 MB of
  data); kernel compilation of a plugin-scale package (a handful of files)
  is the cheap half; the expensive step is upstream's wasm-opt pass at
  `-O1`/`-O2`.
- **Recommendation: skip wasm-opt entirely.**
  [dart-lang/sdk#63301](https://github.com/dart-lang/sdk/issues/63301)
  documents wasm-opt taking ~3 minutes to even fail on a real Flutter web
  build and independently catching validator-invalid dart2wasm output;
  tina does not need optimized compiler output — it needs correct bytes.
  This also removes `io_util.dart`'s `Process` usage, shrinking the io
  quarantine of Q3.
- Practical default until measured: a large fixed fuel budget per compile
  plus an epoch deadline as the wall-clock backstop, in the compiler's own
  capped store; record first measured numbers in this section. Flag
  spellings to verify against the installed wasmtime version at
  implementation time (the CLI fuel/epoch option names were not confirmed
  this session; the C API surface is the actual dependency).

### Q5: Dill-loaded plugins under the VM-interpreter runtime — permission model?

**As a general third-party plugin tier: no. As tina's internal,
base-bundle-executed tier: yes, with the same posture dart-live uses.**

- A kernel dill is an executable-artifact format with **no capability
  binding**. WASI grants capabilities at instantiation; a dill's code simply
  runs on whatever embedder natives the VM module provides. The tier
  boundary the whole design rests on — plugins see only what the host links
  — does not exist for dill-loaded code, so anything shared between plugins
  (the VM module, the platform dill, a package bundle) instantly becomes
  transitive trust.
- This matches existing repo policy: `packages/plugins/README.md` — the
  `tina/` namespace is "a naming rule for trusted plugins, not a sandbox for
  arbitrary Dart code"; `tina-wasm-proposal.md` §5 — "no ambient authority."
  A shared VM runtime with a rich native surface violates both. (Note: the
  upstream `--standalone` track makes this tier largely unnecessary — it is
  the better isolation story for the same "run Dart under wasmtime" need.)
- The workable shape, if the VM-interpreter tier is pursued:
  per-plugin separate VM module instance (VM + platform dill duplicated per
  plugin — memory cost ~20 MB/plugin, *estimate*), a minimal embedder native
  surface (`print` only; no fs/net/env, no JS eval), per-plugin epoch and
  memory caps, and dills built only from a pinned base bundle (platform
  dill + approved packages) — the dart-live DPKG pattern minus all
  hostile-input affordances. Never expose `EmbedderJSEval`; never execute
  agent-fetched dills; never share instances. Gate the runtime's own
  capabilities on the same rule as wasm §5: refuse anything `readAll` would
  deny the model.
- Honest framing: this is **isolation by embedder vocabulary, not by
  substrate** — reconstructing WASI's structural guarantee as a smaller
  import surface, without WASI's machinery enforcing it. Defensible for
  tina's own toolchain tier; any third-party tier should use the wasm route,
  which has a real trust story. The `tina/` namespace rule therefore does
  **not** extend to dill-loaded code: dill plugins are trusted-compiled
  artifacts from the pinned base bundle, and their ids live in the
  application namespace, not user-namespace config.
