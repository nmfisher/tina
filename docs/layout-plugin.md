# Layout strategy plugins (runtime-swappable layout)

Status: design, committed before implementation per the principal's
directive. Branch `codex/layout-plugin` (off `codex/tui-autolayout` @
`19491d85`). The wasm host routing lands in the wasm.dart repository on
`main`; the two repos ship as a pair (like every host-import change since
stage 3 — see `packages/libraries/tina_wasm/README.md`).

Goal: layout *strategies* become installable plugins. The contract (what a
rectangle is, what a spec is) stays core and versioned; the *policy* for
turning a spec into rects becomes swappable at runtime, agent-authorable,
and safely ignorable. The built-in solver stays compiled into the TUI
(native AND wasm) as the fallback path — a plugin replaces the strategy,
never the capability.

## 1. The contract: `tina:layout@1.0.0`

One WIT package, vendored byte-identically in both repositories
(`packages/plugins/tina_layout_plugins/wit/deps/tina-layout/layout.wit` in
tina, `pkg/tina_wasm_host/wit/deps/tina-layout/layout.wit` in wasm.dart).

Three interfaces:

- **`tina:layout/types`** — the GridSpec vocabulary as structured records:
  `track` (kind fixed/weighted/auto, size, weight, min/max units),
  `span` (explicit start or auto-flow, span count), `layout-item`
  (id, placement, per-axis min/max units, aspect hint, priority),
  `layout-spec` (columns/rows/items), `cell-metrics` (rows-per-unit),
  and the solution records: `cell-rect`, `layout-drop`, `layout-solution`
  (rects keyed by item id, track sizes, drops, overflow/gap reports).
  **Plugins never change what a rectangle is** — the records are the
  core `tina_layout` types serialized once, in one codec, shared by the
  guest, the host and every test.
- **`tina:layout/strategy`** — what a layout *plugin* exports:
  `describe() -> {id, version, description}` and
  `solve(spec, columns, rows, metrics) -> result<layout-solution, string>`.
  Pure function, synchronous, structured records in and out.
- **`tina:layout/bridge`** — what the **TUI** imports (host interface,
  added to the `tui-app` world):
  `describe() -> option<strategy-descriptor>` (`none` = no plugin
  mounted) and `solve(spec, columns, rows, metrics)
  -> result<layout-solution, fallback>` where `fallback` is
  `no-plugin | plugin-error(string) | plugin-timeout(string)`.

Worlds: `layout-plugin { export strategy }` for the plugins; the bridge is
an import of the existing `tui-app` world. The engine (`engine-probe`)
does not import the bridge — it never lays out.

## 2. Host routing (wasm.dart, `main`)

Components never call components. The TUI's `bridge.solve` crossing is
answered by the Rust host, which owns the layout plugin's Store:

- `LayoutPluginRuntime` (new `src/tina_layout.rs`): loads a component
  artifact, admits it only if it **exports `tina:layout/strategy@1.0.0`
  and imports nothing but WASI, the dart trace/timeline stubs and the
  contract's own types-only `tina:layout/types@1.0.0` interface** (the
  WIT mechanism for an exported interface that `use`s records; no
  functions, nothing to call through — zero capabilities, fail-closed), instantiates it in its own Store with
  memory/table limits and the shared epoch machinery, and calls
  `solve`/`describe` through dynamic `Val` records under a per-call epoch
  deadline — the same techniques as `plugin_loader.rs`, minus the
  engine-service broker (there is nothing to mediate: the plugin has no
  capabilities).
- A trap (including the epoch deadline killing a wedged solver) retires
  the Store; the next call re-loads from the artifact bytes. A wedged
  layout plugin can cost one deadline interval, never the screen.
- Runner flags: `--layout-plugin=<path>` (mount), `--layout-plugin-watch`
  (re-read the artifact per call — the dev hot-swap loop, mirroring
  `--plugin-watch`), `--layout-plugin-deadline=<ms>` (default 250 ms).
- The bridge host implementation is wired into the `tui-app` linker
  alongside `tina:term`/`tina:plugin-host`: `describe` reports the
  mounted strategy (or none), `solve` routes to the plugin Store and
  classifies failures into the `fallback` variants (epoch-deadline traps
  → `plugin-timeout`).

## 3. Dispatch + fallback (tina repo)

`tina_layout` grows the strategy seam, all synchronous (layout happens
deep inside synchronous render/resize paths; the host bridge is a sync
import like `tina:term/tty.get-size`):

- **`LayoutStrategy`** — `describe()` + `solveSpec(spec, columns, rows,
  metrics)` over the core types; **`BuiltinLayoutStrategy`** wraps
  `GridSolver` (unchanged, still the product).
- **`LayoutWire`** — the one serialization between core types and the
  boundary records (JSON-shaped maps ↔ GridSpec/GridSolution). The plugin
  guests, the host parity tests and the differential goldens all use this
  codec; there is no second serialization to drift.
- **`LayoutStrategies`** — the process-wide dispatcher: `install`,
  `uninstall`, `active`. `ScreenLayout.fromSize` (and the image overlay
  grid) solve through it. Dispatch rule: try the installed strategy; on
  error, timeout flag or absence, fall back to `BuiltinLayoutStrategy`
  and fire a **once-per-install** notice callback (the TUI surfaces it in
  the notice strip). Nothing installed → the dispatcher is the built-in
  solver by identity (zero regression, zero overhead beyond a no-op
  indirection).

The wasm TUI (`tina_wasm`) installs a `BridgeLayoutStrategy` at boot that
calls the host bridge and maps `fallback` onto the dispatcher's fallback
path. The native TUI installs nothing — the built-in solver is the
no-plugin default there by construction (native Dart does not instantiate
wasm components; plugin mounting is a wasm-host concept).

## 4. Zero-capability claim, verified

A layout plugin is a pure function over records: no session store, no
filesystem, no network, no engine-service import. The admission check
enforces it structurally (any `tina:*` import besides the bridge's own
records is refused at load), the registry manifests carry
`"capabilities": []`, and the installer's consent flow therefore asks for
**nothing** — pinned by a client test (the manifest render shows no
capability blocks).

## 5. The two demos

1. **Parity (the differential goldens)** — the entire golden battery
   (every spec from `tina_layout`'s tests plus resize sweeps) runs through
   the plugin path — spec → `LayoutWire` records → guest solve → records →
   `GridSolution` — and must equal the core solver byte-for-byte on the
   golden tables. Two levels: Dart (record round-trip through the same
   code the guest runs) and Rust (the built component, through the real
   Store + `Val` boundary, against JSON goldens exported from Dart).
2. **Swap** — `tina/layout-focus`, a deliberately different strategy
   (equal-share weighted tracks instead of declared weights: the chat/info
   split goes 65/35 → 50/50 on wide terminals), plus
   `tina/layout-hang`, a wedge fixture whose `solve` never returns
   (epoch-kill demo). Installing focus visibly changes the chat screen;
   uninstalling returns the default; hanging falls back after one
   deadline with a notice.

## 6. What stays out (flagged)

- In-session install/uninstall *surfacing* (a `/layout` command or
  plugin-admin integration) is follow-up: the dispatcher supports it
  (install/uninstall take effect on the next solve), and the host
  `--layout-plugin-watch` loop demonstrates live strategy replacement,
  but no TUI admin panel ships in this slice.
- The native launcher does not wire `--layout-plugin` into `tina plugin
  install` for the TUI leg yet (the engine leg's `--plugin-component`
  wiring is the template); the runner flag is the mount surface today.
- `layout-solution.rects` is a list of `{id, rect}` records, not a map:
  WIT has no map type; order is item-declaration order.
