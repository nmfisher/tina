# Native layout strategies

Swappable screen arrangements for native tina — 100% Dart, no wasm, no
registry, no consent machinery. Drop a strategy name into the config
(or `/layout focus` at runtime): the chat screen rearranges. Remove it:
the default returns.

This is the native companion to the wasm plugin round
(`docs/layout-plugin.md`, PR #90's sibling work): **same spec
vocabulary, two runtimes**. A strategy here solves the same `GridSpec`
(`packages/tina_layout`) the `tina:layout@1.0.0` contract ships to
wasm guests, so a native strategy ports to the plugin form by wrapping
its `solve` in a `tina:layout/strategy` guest — and vice versa.

## What ships

| name | arrangement |
|---|---|
| `default` | The compiled-in grid solver: chat 65 / info 35, split from 100 columns. |
| `focus` | Equal halves — weighted tracks share equally (50/50), split from 80 columns. The wasm round's `tina/layout-focus` semantics. |
| `two-column` | Info panel LEFT (38%), transcript right (62%), split from 80 columns — the mirrored screen. |

## Using them

Config (`config` file; the top-level key is canonical, the `[default]`
form is accepted):

```toml
layout_strategy = "focus"      # or put it under [default]

[default]
model = "main"
```

Live, in the chat:

```text
/layout            -> layout strategy: focus (available: default, focus, two-column)
/layout two-column -> layout strategy: two-column (persists for this session; ...)
/layout default    -> back to the built-in
```

The TUI re-solves the screen on the spot (same path as a resize). An
unknown name — in config or at `/layout` — is refused with one notice
and the built-in stays; a strategy that *throws* at solve time falls
back to the built-in solver for that solve, once per install. The
settings panel carries the same choice (`tina/layout/strategy`,
`layout_strategy` in config).

## Writing one

```dart
import 'package:tina_console/tina_console.dart';
import 'package:tina_layout/tina_layout.dart';

/// Equal-share like focus, but never splits below 96 columns.
final class WideFocusStrategy implements ScreenLayoutStrategy {
  const WideFocusStrategy();

  @override
  String get id => 'acme/wide-focus';

  @override
  StrategyDescriptor describe() => const StrategyDescriptor(
      id: 'acme/wide-focus',
      version: '1.0.0',
      description: 'Equal halves from 96 columns.');

  @override
  ScreenPolicy? policyFor(
          {required int width,
          required int height,
          required bool hasMenuBar,
          required int sidebarWidth}) =>
      ScreenPolicy(
          forceSplit: width - sidebarWidth >= 96,
          minSplitWidth: 48,
          chatWeight: 50,
          infoWeight: 50);

  @override
  GridSolution solveSpec(GridSpec spec,
          {required int columns,
          required int rows,
          CellMetrics metrics = CellMetrics.standard}) =>
      const FocusLayoutStrategy().solveSpec(spec,
          columns: columns, rows: rows, metrics: metrics);
}
```

Register it in your composition root before the session assembly
starts:

```dart
import 'package:tina/tui.dart';

void main(List<String> args) {
  registerLayoutStrategy('acme/wide-focus', WideFocusStrategy.new);
  // ... the usual session startup
}
```

The name is then valid in config (`layout_strategy =
"acme/wide-focus"`) and at `/layout acme/wide-focus`.

Two levels are available:

* **`LayoutStrategy`** (`tina_layout`) — the wasm contract's shape:
  `solveSpec(spec, columns, rows, metrics)`. It sizes the tracks of whatever spec
  the screen hands it. This is all a strategy needs if it only wants to
  redistribute space.
* **`ScreenLayoutStrategy`** (`tina_console`) — adds `policyFor`:
  template knobs (force the split, move its threshold, change the
  weights, mirror the columns). This extension has no wasm counterpart
  — wasm plugins never reshape the template, only track sizes.

Implementations must be pure and synchronous: no I/O, no clocks, no
terminal access. Solve-time throw = one-solve fallback to the built-in.

## Why compiled-in registration, not a strategies directory

The wasm round loads strategy *components* at runtime because that is
what a wasm host can do safely: zero-capability admission, epoch
deadlines, kill-and-fallback. Native Dart has no equivalent that is
worth its complexity:

* An AOT-compiled binary cannot load Dart code at runtime at all; a
  `spawnUri`-style loader exists only on the JIT VM, would fork
  isolates per strategy, and would still not isolate anything the
  strategy touches — see below.
* Native strategies are **trusted code** by definition: they run in the
  same process, same isolate, with the full standard library. There is
  no capability boundary to enforce, so there is nothing a consent flow
  could meaningfully ask about. Isolation guarantees are explicitly out
  of scope here — if you need untrusted strategies, that is what the
  wasm registry round is for.

So the pragmatic native mechanism is: your strategies live in your
application's Dart (workspace package), are compiled in, and are
registered by name via `registerLayoutStrategy` — the binary is the
directory. The built-in presets (`default`, `focus`, `two-column`) are
pre-registered.

## Relationship to the wasm plugin round

The two rounds now share ONE dispatcher (`LayoutStrategies` in
tina_layout): native presets, workspace-registered strategies and the
wasm bridge plugin all install into the same slot and fall back the
same way. Same vocabulary, two strategy sources:

* Both solve `GridSpec` → `GridSolution` from `tina_layout`; the wasm
  contract (`tina:layout@1.0.0`) serializes those records across the
  Store boundary, this variant calls the interface directly.
* Both fall back to the compiled-in solver on any strategy failure,
  with one notice.
* The wasm round's plugins are untrusted, capability-admitted,
  epoch-deadline-bounded — but isolated, not trusted; native strategies
  are trusted, registered at compile time, and additionally allowed to
  reshape the template (`ScreenPolicy`) — something the wasm side
  deliberately cannot do.

## Tests

* `packages/tina_layout/test/layout_strategy_test.dart` — built-in
  parity, focus equal-share, floors, dispatcher fallback + one-notice,
  listeners.
* `packages/tina_console/test/screen_layout_strategy_test.dart` —
  goldens per strategy (100/120/80/60 columns, menu box), the live
  swap (install moves the screen, uninstall restores byte-for-byte,
  `split:false` override), throwing solve and throwing policy fallbacks.
* `apps/tina_cli/test/layout_command_test.dart` — `/layout` reporting,
  live swap + restore, unknown names, config boot selection, malformed
  config values, `registerLayoutStrategy`.
