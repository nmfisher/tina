# WASM ecosystem research notes (tin-w4sm context)

Status: research notes; no phase scope change.
Date: 2026-09-24
Baseline reviewed: `wasm-plugin-support` branch (Phase 0 prototype, vendored
Wasmtime v36.0.15).

## 1. Why this exists

A shared DeepSeek conversation
(`https://chat.deepseek.com/share/yoi3gqa56p97zbw90k`) exploring Plan 9 ×
WebAssembly was reviewed to check whether anything in it affects the WASM
plugin plan (phased proposal `wasm_plugin_support.md`, lives on the
`wasm-plugin-support` branch). Verdict up front: **nothing changes phases
0–4**. The notes below record what was verified, corrected, or could not be
verified, plus the landscape as of September 2026 for future reference
(relevant at most to Phase 5/6 design discussions).

## 2. Fact-check of the shared conversation

| Claim in the chat | Verdict | Evidence |
|---|---|---|
| Wanix is a Plan 9-inspired browser runtime: namespace kernel, everything-is-a-file, 9P import binds, task drivers for Go-wasm/WASI/JS, v86 VMs | **Verified** | `tractordev/wanix` (~843 stars, pushed 2026-08), wanix.sh. Kernel ships as `wanix.wasm`; HTML elements (`wanix-namespace/-bind/-task/-term/-vm/-workbench`); `<wanix-bind type="import">` does 9P over WebSocket/iframe |
| Wanix runs natively outside the browser (CLI, Mac/Win/Linux) — "yes, you can run your wasm binary in it headless" | **Partially verified / time-sensitive** | The May 2026 capture of wanix.sh (0.3.x era) says "runs in the browser as well as natively on Mac, Windows, and Linux" with a CLI toolchain (`wanix serve`, wanix.run distro). The current 0.4 site/repo is browser-first ("No server"); today's Go CLI (`cmd/wanix`, build tag `!js && !wasm`) exposes only `serve` — a host/relay, not an execution kernel on the current main branch. The chat's how-to mixed browser flows (OPFS drag-drop, `domctl`, `/web/...` paths) into a supposedly native answer |
| Ricket: WASM runtime for Plan 9, frontend/toolset for wazero | **Verified** | `SlashScreen/ricket`: 9front mk-installable wazero frontend; beta; goals = run WASI at all / on Plan 9 / as packaged apps. Last code push **2023-09**; effectively dormant |
| wazero: pure-Go, zero-dependency, no-CGO wasm runtime; compiler + interpreter; WASI | **Verified** | `wazero/wazero`; spec-compliant 1.0/2.0; embeddable — the engine inside Ricket, and of Wanix's WASI task driver lineage |
| w2c9: translates wasm modules to C for Plan 9 (port of w2c2) | **Verified to exist; niche** | `euclaise/w2c9` — a **fork** of w2c2 ("Translates WebAssembly modules to C (Plan 9 edition)"): wasm → C89 to build with Plan 9's toolchain. Upstream w2c2 passes ~99.9% of the core semantics suite with a partial WASI. An AOT transpiler, not a runtime; hobby scale |
| plan9_webasm: Plan 9 C libs/devices/Inferno ported to wasm (2018, "first Unix-derived OS on wasm") | **Exists but dead** | `xphung/plan9_webasm` — 2018, no meaningful code/activity since |
| "Jetstream — RPC framework building on 9P and QUIC, targeting WebAssembly" | **Unverified — treat as confabulated** | GitHub search for jetstream + 9p/quic returns nothing; no repo, site, or doc found. Do not cite |
| WebAssembly interpreter being written in Limbo (iwp9 proceedings) | **Plausible, unverified this session** | Referenced to an iwp9 proceedings PDF; academic/historical, no maintained artifact found |
| (Additions from this session's own research, not in the chat) | | **Halatha** (`kiljoy001/halatha`, created 2026-08): divergent Wanix fork — whole-disk 9front/9legacy boots under v86, virtio-9p host bridge, WebUSB via a guest HCI driver. **star9**: tiny Rust Plan 9-inspired OS with WASI. **wasm2go** (`goccy/wasm2go`, active 2026-09): wasm → standalone Go+asm; its "Plan 9 Assembly" tagline means Go's asm syntax, **not** the Plan 9 OS — common search false positive |

## 3. Landscape, September 2026

Two directions, lopsided activity:

- **WASM *on* Plan 9** — thin: Ricket (dormant since 2023) and the w2c9
  transpile route. No maintained port of wasmtime/wasmer/wasm3 to 9front;
  nothing newer than Ricket.
- **Plan 9 *in* the browser** — where the activity is: Wanix (active),
  its Halatha fork (new, Aug 2026, deepens the Plan 9 guest story via v86),
  plus older one-off ports.
- **Native Plan 9-type systems** — the mature half: 9front (release
  "This Was Supposed to Be Fun", Aug 2026), 9legacy, Inferno (quiet),
  Harvey (archived). Plus Plan 9 *ideas* inside mainstream systems
  (plan9port, diod/u9fs 9P servers, Fuchsia namespaces).
- **Gap**: no maintained *native* embeddable namespace runtime
  ("Wanix for native": host binary + wazero tasks + 9P-served namespace).
  The pieces exist in Go; nobody has assembled them into a maintained
  product. Native platforms already have processes/namespaces, so the
  runtime model mainly pays off where they don't — the browser.

## 4. Implications for the tina plan (tin-w4sm)

- **Runtime choice stands.** Vendored Wasmtime is the only candidate that
  meets the Phase 0 gate: pinned maintained release, per-target archives
  with provenance, epoch-interruption cancellation with native evidence.
  wazero is Go-only (wrong host language). w2c9-style AOT transpilation
  contradicts the plan's posture — it pre-trusts guest bytes at compile
  time and widens attack surface; the plan requires byte validation at
  preparation against the shipping runtime. Browser runtimes are
  irrelevant to headless tina.
- **No re-scoping.** Nothing in the ecosystem offers a shortcut for
  Phases 1–3 (ABI, async lifecycle, end-to-end integration) or weakens the
  fail-closed/brokered-capability contracts.
- **Idea bank for Phase 5 only.** The 9P/namespace pattern is a design
  reference for the capability broker — exposing confined host operations
  as file-like, per-conversation resources — consistent with the Phase 5
  rule of starting from one narrow brokered operation. Reference only;
  not a commitment, and no WASI/preopen shortcuts either way.
- **Correction to prior discussion** (recorded for honesty): Wanix 0.3.x
  did ship a native host alongside the browser; the current main branch is
  browser-first with a `serve`-only Go CLI. "Browser-only" was true of the
  0.4 kernel, not of the project's whole history.

## 5. Dart ↔ WASI status (September 2026)

Fact-check of a second shared AI conversation (dart2wasm/WASI summary). All
GitHub references verified against the API on 2026-09-24; two states had
moved since the conversation was written.

### The pipeline (dart2wasm → standalone runtimes)

- **Issue #53884** `[dart2wasm] Support non-JS wasm runtimes` — **open**
  (updated 2026-08-25), the master tracker: decouple dart2wasm output from
  JS host functions (event loop/timers, printing, double→string, RegExp,
  stack traces) via an experimental `--standalone` mode with documented
  host imports (`sdk/lib/_internal/wasm/standalone/embedder.dart`).
- **Issue #56366** `[proposal] [dart2wasm] Wasm component model / WASI
  support` — **open**, enhancement proposal, modest activity (8 comments).
- **Issue #63166** `Split dart:_wasm to avoid dart:js_interop import` —
  **closed 2026-07-29**; the chat's "active blocker" framing is stale, this
  landed.
- **Issue #54394** `[dart2wasm] Use new exception instructions` —
  **closed**; likewise done, not a live Wasmtime compatibility blocker.

### Ecosystem

- **`simolus3/wasm.dart`** ("Tools to run Dart in any WebAssembly runtime"):
  `wasm_tools` (Dart → component CLI, WIT bindings) + `wasm_components`
  (component-model runtime for Dart). Compiles via the experimental
  `--standalone` mode and resolves SDK host imports by linking Dart-written
  `@pragma('wasm:export')` implementations back into the module. Self-
  reported status: **"can't handle much more than a hello world program."**
  Its embedder-import table is the clearest public map of the remaining
  work: string ops and clocks ✅; scheduling requires host imports 📦;
  weak refs / expandos / finalizers / stack traces are 🛑 (fundamentally
  unavailable under Wasm GC today — stubs only).
- **`wasd`** (medz/wasd, pub.dev v0.5.0, 2026-08-04): the *opposite
  direction* — a pure-Dart WebAssembly **runtime/host** for the Dart VM:
  WASI preview1 runner plus Dart VM execution of WASI 0.2.12
  command/proxy and 0.3.0 command/service components. Single maintainer,
  first release 2026-02, 0.x.

### Verdict for tina

- Neither project changes tin-w4sm. `wasd` is an interpreter-class pure-
  Dart host: it cannot satisfy the Phase 0 gate (pinned maintained native
  runtime, provenance, epoch-interruption cancellation, native FFI
  evidence) and is younger and less exercised than the vendored Wasmtime.
  `wasm.dart` is about *emitting* Dart as components — irrelevant to
  executing untrusted C-compiled plugin guests.
- Worth re-checking at Phase 4 time: if `--standalone` matures, a future
  option is compiling *tina head tools* (or the worker) into components to
  run under foreign runtimes — the direction our `spikes/dart_wasm_worker`
  (workerd) probe already pointed at. Monitor #53884; do not plan on it.

## 6. Sources (accessed 2026-09-24)

- https://github.com/tractordev/wanix (+ cmd/wanix/main.go, raw README)
- https://wanix.sh/ (current, 0.4-rc2 era) and
  https://web.archive.org/web/20260509231038/https://wanix.sh/ (0.3 era)
- https://github.com/SlashScreen/ricket (+ raw README)
- https://wazero/wazero via conversation claims and Ricket docs
- https://github.com/euclaise/w2c9 (+ raw README, upstream w2c2 content)
- https://github.com/kiljoy001/halatha (+ raw README)
- https://github.com/goccy/wasm2go (+ raw README)
- https://github.com/Apothic-AI/star9, https://github.com/xphung/plan9_webasm
- GitHub/HN/GB search queries: plan9+wasm, 9front+wasm, jetstream 9p quic
  (0 results), HN "9front" (Aug 2026 release thread)
- Dart SDK issues: dart-lang/sdk#53884 (open), #56366 (open), #63166
  (closed 2026-07-29), #54394 (closed) — via GitHub API
- https://github.com/simolus3/wasm.dart (+ raw README, embedder-import
  table); https://pub.dev/packages/wasd (v0.5.0, published 2026-08-04)
