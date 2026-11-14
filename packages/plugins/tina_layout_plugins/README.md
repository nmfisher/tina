# tina_layout_plugins

Layout strategy plugins for the `tina:layout@1.0.0` contract
(`docs/layout-plugin.md` in the repository root): the compiled
components a tina host mounts with `--layout-plugin=<artifact>` to
replace the TUI's layout *strategy* at runtime. The contract — what a
rectangle is — stays core; only the strategy swaps.

| artifact | id | what it does |
|---|---|---|
| `bin/layout_solver.wasm` | `tina/layout-solver` | The built-in tina_layout solver as a plugin: rects identical to the compiled-in fallback by construction (the parity reference). |
| `bin/layout_focus.wasm` | `tina/layout-focus` | The deliberately different demo: weighted tracks share the remaining space equally (the chat/info split goes 65/35 → 50/50 wherever the app allows a split). |
| `bin/layout_hang.wasm` | `tina/layout-hang` | TEST FIXTURE: `solve` never returns; the host must epoch-kill it at the deadline and the TUI must fall back. |

All three declare **zero capabilities**: they import nothing beyond WASI
and the contract's own types interface; the host refuses anything else
(pinned by a Rust admission test).

## Layout

- `wit/deps/tina-layout/layout.wit` — the contract (vendored identically
  in wasm.dart's `pkg/tina_wasm_host/wit/deps/tina-layout` and
  `tina_wasm/wit/deps/tina-layout`).
- `lib/src/generated/` — witgen output (committed).
- `lib/src/plugin/` — the wire codec and the strategies as plain Dart
  (`SolverLayoutStrategy`, `FocusLayoutStrategy`, `HangLayoutStrategy`),
  testable on the VM; the guests in `bin/` are thin adapters.
- `test/differential_test.dart` — the differential goldens: the whole
  battery (chat grids, edges, aspect, auto-flow, resize sweeps) through
  the plugin path must be byte-identical to the core solver; focus must
  differ wherever weighted tracks share; the swap changes the screen and
  uninstall restores it.
- `tool/export_goldens.dart` — writes the JSON golden table the wasm.dart
  host replays through the real Store (`testdata/layout/goldens.json`).

## Rebuild

Requires the pinned Dart 3.14 SDK and the wasm.dart checkout on PATH
(see `pubspec_overrides.yaml`, gitignored — same pattern as `tina_wasm`):

```sh
export PATH=/path/to/dart-sdk-3.14/bin:$HOME/.cargo/bin:$PATH
dart pub get
dart run wasm_tools witgen -i wit -w tina:layout-app/layout-plugin \
  -o .dart_tool/witgen
cp .dart_tool/witgen/tina_layout.dart \
   .dart_tool/witgen/tina_layout_app_layout_plugin.* \
   lib/src/generated/
for guest in layout_solver layout_focus layout_hang; do
  dart run wasm_tools compile bin/$guest.dart
  dart run wasm_tools stamp-abi bin/$guest.wasm -o bin/$guest.wasm
done
```
