# Generated WIT interop for this package's world.

The bindings under `lib/src/components/` are generated; regenerate with

    ./tool/generate.sh

The vendored WIT under `wit/deps/` is not authored here:

- `wasi-*` are the WASI 0.3.0 interface definitions, copied verbatim from
  the `wasi` package of nmfisher/wasm.dart (branch `asb/wasm-stage3-ports`,
  `pkg/wasi/wit/deps`).
- `tina-http` is the `tina:http@1.0.0` host interface, defined by the Rust
  host in that same repository (`pkg/test_runner/wit/deps/tina-http`).
- `tina-process` is the `tina:process@1.0.0` host interface (spec:
  `pkg/test_runner/docs/tina_process.md`), from
  `pkg/test_runner/wit/deps/tina-process` in the same repository.
- `wasmdart-tests` is the case-runner protocol (`pkg/test_runner/world.wit`).

When either repository changes those files, refresh the copies here and
regenerate.
