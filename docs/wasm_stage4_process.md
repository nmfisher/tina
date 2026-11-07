# Stage 4 — process execution across the boundary

Program context: the engine2 agent loop compiles to wasm and runs under
wasmtime (stage 3 landed `tina:http`, WASI preopens, and the exit probe).
WASI has no process spawn, so stage 4 adds the missing capability: **the
HOST executes real processes on the engine's behalf, behind a policy the
engine cannot bypass.**

## What landed

### wasm.dart (`asb/wasm-stage4-process`)

- `pkg/test_runner/docs/tina_process.md` — the spec, written first.
- `wit/deps/tina-process/tina_process.wit` — `tina:process@1.0.0`:
  `spawn` (argv, cwd, env, stdin bytes, access profile), `respond`,
  `wait`, `kill`; stdout/stderr as component-model `stream<u8>` values,
  the same lowering `tina:http` bodies use.
- `src/tina_process.rs` — the host implementation: `tokio::process`
  spawn (no shell, no pty, no globbing), profile evaluation *before* any
  process exists, output pipes as `StreamReader` producers, kill-on-drop
  children, and the approval round-trip. Spawn `cwd` values resolve
  against the runner's `--preopen` map with the same confinement
  `WasmFileSystemPort` applies (`..` refused, foreign paths refused).
- Runner flags unchanged; the preopen map gained a second consumer.
- `pkg/wit_bindgen_dart`: package docs now emit the `library;` directive
  *before* imports (it was emitted after them, which dart2wasm rejects);
  the precompiled `.so` is rebuilt locally and gitignored as before.

### tina (`asb/wasm-stage4-wasm-process`)

- `tina_core` — the process policy vocabulary (`ProcessRule`,
  `ProcessAccessProfile`, `ProcessVerdict`), the shared evaluator
  `evaluateProcessPolicy` (anchored first-match, no-match asks, invalid
  pattern fails closed), `ProcessRefusedException` /
  `ProcessLaunchException`, and the approval seam types
  (`ProcessApprovalRequest`, `ProcessApprover`).
- `tina_io` — `IoProcessPort`: `dart:io` behind the same profile, so the
  native side of the boundary evaluates identical rules to identical
  effect (plain `Process.run` semantics when no profile is configured —
  existing native composition unchanged).
- `tina_wasm` — `WasmProcessPort` over the host import: outcomes cross
  as data (`denied` → `ProcessRefusedException`, `approval` → the
  configured approver, whose answer returns via `respond`); streams
  drain concurrently; `signal(n)` maps to `-n` like `dart:io`.
  The pubspec pins wasm.dart `asb/wasm-stage4-process`.
- The process exit probe (`process_probe_body.dart`,
  `bin/process_probe.dart`, `bin/native_process_probe.dart`,
  `tool/process_exit_test.sh`).

## The approval round-trip

Wasmtime cannot call a guest export while the guest is blocked in a host
call, so `ask` does not call back — it *returns* to the engine:

1. `spawn` answers `approval { id, command, reason }` immediately; no
   child exists.
2. The engine routes `command`/`reason` through its approval flow. The
   probe uses tina_mode's real policy table
   (`resolveAuthorization`, `PermissionMode.ask`): an unremembered
   workspace command routes `human` — "Workspace mutation requires
   approval".
3. The answer (`respond`) returns to the host; only `allow` spawns.

The reason strings are interface contract: the Rust host and the Dart
evaluator produce the same words, and `tina_core`'s
`process_policy_test.dart` mirrors the Rust unit tests case for case.

## Where enforcement lives

The engine *sends* the profile; the host *enforces* it — the host is the
only side that can spawn, it anchors every pattern, fails closed on
invalid patterns, confines `cwd` to preopens, and remains the chokepoint
for tightening (a runner-side deny list needs no interface change). The
profile is data, not authority.

## Verification (2026-11-07)

- wasm.dart: `cargo test` 11/11 (8 new `tina_process` tests incl.
  kill→signal wait and cwd confinement); case suite `dart test` 26/26;
  wasm_tools `dart test` 11/11.
- tina: `tina_core` 33/33, `tina_io` 3/3.
- Process exit test: `tool/process_exit_test.sh` →
  **IDENTICAL: 22 recorded lines match** — `git status` through the host
  byte-identical to native (same repo, same output), stdin piping and
  env merge through an approved spawn, the approval flow firing
  (host `ask` → tina_mode `route: human` → granted → command runs), and
  `rm` denied with `rule 1 (rm .*) denies the command` before any
  process existed.
- Stage-3 exit test re-run after the world grew: IDENTICAL, 23 lines.

## Open unknowns / deviations

- `kill` is exercised host-side (cargo unit test: SIGKILL → `wait`
  reports `signal(9)`), not across the boundary: `ProcessPort`'s
  contract is run-to-completion, so the Dart port never needs it. The
  WIT surface carries it for a future streaming consumer.
- The wasm child inherits the *runner's* environment (merged with the
  spawn's `env`), exactly as `dart:io` children inherit the native
  process's; parity in the exit test holds because both runners share
  the shell environment.
- `tina:http` TLS and the narrowed WASI world remain stage-3 notes.
- tina's wasm.dart git deps point at the (locally collected, unpushed)
  `asb/wasm-stage4-process` branch; local development used
  `pubspec_overrides.yaml` (uncommitted, as in stage 3).
