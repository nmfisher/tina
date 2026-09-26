# dart_wasmtime

Vendored [Wasmtime](https://wasmtime.dev) C API for tina's WASM plugin runtime
(`.tickets/tin-w4sm.md`, Phase 0).

- **Pinned**: Wasmtime v36.0.15 (even-minor LTS), C API **full** profile (the
  `min` profile cannot compile/validate modules, which Phase 1 requires).
- **Packaging**: one static archive per target under
  `native/lib/<os>_<arch>/libwasmtime.a`, each with a `SHA256SUMS` sidecar and
  tarball provenance hashes recorded in `hook/build.dart`. Linked into native
  assets by `hook/build.dart`, mirroring `packages/dart_notcurses`.
- **License**: Apache-2.0 (see `NATIVE_LICENSE.txt`, from the v36.0.15 source
  tree). WASI symbols are present in the archive but tina never initializes
  WASI — API 1 plugins get no host capabilities.
- **Worker**: `bin/worker.dart` is the supervised worker process
  (`lib/src/worker.dart` is the supervisor). Guest calls run on a helper
  isolate so the main isolate can bump the epoch for cancellation; guests never
  execute on the agent/UI isolate.
- **Tests**: `dart test` runs real Wasmtime against a real compiled guest in a
  real supervised process — see `test/phase0_native_test.dart` and
  `docs/proposals/wasm_plugin_support_phase0_results.md` in the repo root.
