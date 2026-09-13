# Phase 0 results — Wasmtime packaging & supervised worker cancellation

Record for the Phase 0 exit gate of
[WASM plugin support](wasm_plugin_support.md) (`.tickets/tin-w4sm.md`).

**Status: PARTIAL — Linux x64 proven end-to-end; macOS ARM64 and Linux ARM64
are packaged and checksummed but UNVERIFIED.** Phase 0's box in the ticket
stays unchecked until all three targets have native evidence; do not treat the
unchecked box as a regression of the work below.

## Environment

| Item | Value |
| --- | --- |
| Date | 2026-09-12 |
| Host | Linux x86_64 (container, no docker/podman available) |
| Dart SDK | 3.13.1 (stable) |
| Guest toolchain | Ubuntu clang 18.1.3, `--target=wasm32` + `wasm-ld` |
| Wasmtime | v36.0.15 (even-minor LTS), C API **full** profile |
| Binding | hand-written `@Native` C bindings (package `dart_wasmtime`), no interpreter, no mocks |

The **full** profile is required: the `min` profile lacks
`wasmtime_module_new`/`wasmtime_module_validate`, which Phase 1's byte
validation needs. WASI symbols exist inside the archive but tina never
initializes WASI (API 1 forbids host capabilities).

## Packaging (pinned v36.0.15, vendored static archives)

Vendored per target under `packages/dart_wasmtime/native/lib/<os>_<arch>/`,
each with a `SHA256SUMS` sidecar; provenance sha256s of the release tarballs
are recorded in `packages/dart_wasmtime/hook/build.dart`:

| Target | Archive size | Archive sha256 |
| --- | --- | --- |
| linux_x64 | 50,738,912 B | `0043943b9ce14ee714a681337ece1acb414de602b643fe962bc33de876f6e6ab` |
| linux_arm64 | 46,076,956 B | `aac52e91498a1327d5e59eae4a27853107024214f0177f194c1ae8907f755696` |
| macos_arm64 | 28,875,408 B | `3e2e647c8d6d858fc88cf8dc6411da1b9fa404ba84d1ea1a99e19539986f6fe7` |

Build hook (`hook/build.dart`) mirrors `dart_notcurses`: per-target static
archive linked with `-Wl,--whole-archive` (ld) / `-force_load` (ld64).
`dart build cli` at the repo root succeeds and produces
`libwasmtime_merged.so` (25,195,528 B) with the Wasmtime exports verified
present.

## What the tests prove (all native, no mocks/interpreters)

`packages/dart_wasmtime/test/phase0_native_test.dart`, 7 tests, all green,
`dart analyze` clean at repo root and in the package:

1. **packaging** — the vendored archive resolves through the build hook; the
   real validator accepts the checked-in guest and rejects garbage bytes.
2. **ABI** — guest bytes compile/instantiate; `add`, `count_loop` calls cross
   the FFI boundary with correct i32 semantics.
3. **supervised worker** — the guest runs in a **separate process** (`pid !=
`test pid`), never on the agent/UI isolate.
4. **cancellation** — a `spin_cycles(INT32_MAX)` guest (a loop LLVM cannot
   fold; each iteration makes a real call to a `noinline` mix function) is cut
   off by an epoch bump and the worker process is **joined and reaped**
   (`kill -0` confirms the pid is gone); the in-flight call fails rather than
   hangs; cancellation completes well under a 3s ceiling (measured 4–8 ms).
5. **lifecycle/shutdown** — clean shutdown exits 0 and is reaped.
6. **lifecycle/pipe-close** — closing the supervisor's stdin joins the worker
   too; nothing left running.
7. **measurements** — prints the numbers below.

## Measurements (Linux x64 only — other targets pending hardware/CI)

| Metric | Value (typical range across runs) |
| --- | --- |
| guest.wasm size | 562 B |
| compile (validate + compile) | 1.7–16 ms |
| instantiate | 84 µs–1.8 ms |
| trivial call, in-process (n=1000) | 14–27 µs/call |
| worker load + instantiate round trip | ~880 ms (dominated by `dart run` startup of the worker process) |
| worker trivial call round trip | 16–18 ms |
| **worker cancellation latency** (epoch bump → in-flight call fails) | **4–8 ms** |

Residual host limits are not yet committed (module size, concurrency, log
volume, memory ceilings) — those land with the Phase 0 completion on the
remaining targets and feed the defaults table in section 5 of the proposal.

## Threading/cancellation model (the non-obvious part)

`wasmtime_func_call` is synchronous and blocks. If the worker ran it on its
main isolate, the event loop could not read stdin — a `cancel` line could
never be handled while a long-running guest spun, deadlocking the supervisor.
The worker therefore executes each guest call on a short-lived **helper
isolate** (`bin/worker.dart`):

- The main isolate stays responsive: `cancel` bumps the engine epoch;
  Wasmtime's epoch interruption is **cross-thread**, so the guest traps
  "interrupt" at its next epoch check on the helper thread.
- Arming the per-call epoch deadline happens on the main isolate **before**
  the helper enters the guest: deadlines are rebased on the current epoch at
  arm time, so a later re-arm would silently swallow a cancel that raced
  ahead.
- One call in flight per worker; the helper never loads or tears down. A store
  is never entered from two threads at once.
- Teardown order: epoch bump (if a call is in flight) → join helper → close
  instance → close module → close engine → exit.

## Bugs found while proving the ABI (kept as notes for Phase 1)

1. `wasmtime_store_new` takes 3 args (engine, data, finalizer).
2. `wasmtime_linker_instantiate` arg order is (linker, context, module, out,
   trap**).
3. `wasmtime_context_t` ≠ store pointer; use `wasmtime_store_context(store)`.
4. `wasmtime_instance_t`/`wasmtime_func_t` are 16-byte by-value structs.
5. `wasmtime_val_t` is 24 bytes (kind@0, payload@+8); `wasmtime_extern_t` is
   32 bytes.
6. `wasmtime_func_call` returns `wasmtime_error_t*` and takes `trap**` as its
   7th arg.
7. Trap message accessors are the wasm-c-api names (`wasm_trap_message`,
   `wasm_trap_delete`) in v36.
8. Un-zeroed malloc scratch: wasmtime writes trap out-params only on failure —
   zero all scratch before calls.
9. The `wasmtime_instance_t` must be copied out of instantiation scratch;
   using freed scratch aborts later with "object used with the wrong store".
10. Stores start **unarmed** (deadline 0) with epoch interruption enabled — an
    unarmed call traps "interrupt" immediately. Arm per call
    (`WasmtimeEngine(autoArm:)` or explicit `setEpochDeadline`).
11. LLVM folds naive spin loops into closed forms; the guest's `spin_cycles`
    loops through a `noinline` mix function over a global so the loop is real.
12. Supervisor `stop()` must request shutdown **before** marking itself
    stopped — marking first made `_request` throw `StateError`, silently
    swallowed the shutdown, waited out the grace period, and SIGKILLed a
    healthy worker (observed as a fixed ~10 s stop and exit code −9).

## Unverified targets

Both remaining targets ship the same pinned archive with checksums but have
**no native test evidence** in this environment:

- **macOS ARM64** — no macOS host; codesigning/loading under Tina's packaged
  layout untested.
- **Linux ARM64** — no docker/podman in the container to run an arm64
  environment.

Phase 0 completes when CI or hardware proves stuck-worker termination on both
(plus codesign verification on macOS). Until then the ticket's Phase 0 box
remains unchecked by design.
