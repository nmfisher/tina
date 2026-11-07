# Wasm stage 3 — the ports on wasm

Stage 3 of the dart2wasm port: wasm implementations of the stage-2 I/O
ports, so the headless engine runs as a wasmtime component. The package is
`packages/libraries/tina_wasm` (branch `asb/wasm-stage3-wasm-ports`); the
host side landed in the wasm.dart fork (branch `asb/wasm-stage3-ports`).

## What each port uses

| port | wasm implementation | backed by |
|------|--------------------|-----------|
| `HttpClientPort` | `WasmHttpEndpoint` | the `tina:http/client@1.0.0` host import — reqwest in the Rust runner; the response body is a component-model byte stream, chunks as the network delivers them (SSE works) |
| `FileSystemPort` | `WasmFileSystemPort` | `wasi:filesystem/preopens` — read/write/stat/create over descriptors the host preopened; any path outside them (including `..`) is refused |
| `EnvironmentPort` | `WasmEnvironmentPort` | `wasi:cli/environment` (`get-environment`, `get-initial-cwd`) |
| `ClockPort` | `SystemClock` unchanged | `DateTime.now()` is dart:core → embedder `currentTime` → `wasi:clocks` |
| `RandomPort` | `SystemRandom` unchanged | see below |

## Clock and random (the stage-3 verification item)

Both compile under dart2wasm and run under wasmtime with **no port
replacement needed**, verified live by the exit probe:

- `Random()` lowers to the embedder's `randomInt`, which the wasm_tools
  compiler rewrites to `wasi:random/insecure.get-insecure-random-u64`.
- `Random.secure()` lowers to `randomIntSecure`, rewritten to
  `wasi:random/random.get-random-u64`: the secure source is the **host
  OS CSPRNG** behind that WASI interface. There is no in-module fallback
  — the embedder throws `UnsupportedError` if the interface is not linked
  — so a wasm host that links `wasi:random/random` (wasmtime-wasi's p3
  host does) has a real secure source; one that does not fails loudly.

## Host-side requirement found by this stage

Reading a host-provided stream (an HTTP body, a file via
`read-via-stream`) deadlocked in the guest runtime: `StreamReadState`
never joined the readable end into the task's waitable set, so the host's
`StreamRead` event was set on a waitable the guest never waited on. Fixed
in wasm.dart (`wasm_components`, `runtime/async/stream.dart`) — a
one-line `waitable.join`, symmetric with the write side. Every consumer
of `tina:http` response bodies depends on it.

## The exit test

`packages/libraries/tina_wasm/tool/exit_test.sh`: the probe
(`bin/probe.dart` wasm, `bin/native_probe.dart` native) reads a config
TOML through the filesystem port, writes a file and reads it back, and
makes one streaming provider-style call (a real `AnthropicProvider`
against a local fake SSE server, `tool/fake_anthropic_server.py`) through
the HTTP port. Recorded output under wasmtime is byte-identical to the
native run — 23 JSON lines, including each SSE delta as its own chunk.

Credentials never enter a file or the repo: the fake server ignores the
token, and the runner receives `TINA_LLM_TOKEN` via `--env` from the
caller's environment.
