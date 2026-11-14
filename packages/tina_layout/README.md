# tina_layout

Declarative square-grid auto-layout for tina's terminal UIs. **Pure Dart**:
no renderer, no I/O, no notcurses, zero dependencies. The native
(notcurses/ANSI) TUI and the wasm cell-buffer TUI solve the same `GridSpec`
unchanged — layout lives above the renderer split.

## The unit model

The layout unit is a **square screen patch**. Horizontally one unit is
exactly one cell column. Vertically one unit spans `rowsPerUnit` rows —
`2` under the standard terminal cell aspect (~2:1 height:width), so
**1 unit = 1 column x 2 rows** and *half* a unit is a single screen row.
All track sizes and aspect math happen in these square units; solved rects
are emitted in terminal CELLS for direct mapping to notcurses planes or a
virtual cell buffer.

Real cell metrics override the default: `CellMetrics.fromPixels(
cellWidthPx: 8, cellHeightPx: 19)` keeps every spec square-correct without
touching the specs.

## API

```dart
final solution = GridSolver.solve(
  GridSpec(
    columns: [
      GridTrack.fixed(20),                      // sidebar, 20 columns
      GridTrack.weighted(65, minUnits: 30),     // chat pane
      GridTrack.weighted(35, minUnits: 20),     // info pane
    ],
    rows: [
      GridTrack.fixed(1.5),                     // menu box: 3 rows
      GridTrack.fixed(0.5),                     // border: 1 row
      GridTrack.weighted(1),                    // transcript
      GridTrack.fixed(0.5),                     // input row
      GridTrack.fixed(0.5),                     // status strip
    ],
    items: [
      GridItem(id: 'transcript',
          column: const TrackSpan.at(1), row: const TrackSpan.at(2)),
      GridItem(id: 'panel',
          column: const TrackSpan.at(2), row: const TrackSpan.at(2),
          aspectHint: 4, priority: 5),          // see below
      GridItem(id: 'floater'),                  // auto-flow, first fit
    ],
  ),
  columns: 120,
  rows: 24,
);

solution.rectOf('transcript');   // GridRect in CELLS
solution.hitTest(80, 12);        // -> item id under that cell
solution.dropped;                // overflow policy report
```

* **`CellMetrics`** — `standard` (1u = 1 col x 2 rows), `fromPixels`,
  `aspectFromPixels(w, h)` (a square-in-pixels image is ratio `4` at 2:1
  cells because a visually square patch is 4 cols x 2 rows = 4 x 1 units).
* **`GridTrack`** — `fixed(units)`, `weighted(weight)`, `auto()`, each with
  optional `minUnits`/`maxUnits`. Minimums are hard floors; maximums are
  hard ceilings.
* **`TrackSpan`** — `at(i, {span})` for explicit placement, `span(n)` /
  `auto()` for solver auto-flow (first-fit row-major, sparse cursor).
* **`GridItem`** — id, placement, per-axis content `min/max` units (these
  feed `auto` tracks and raise effective track minimums), `aspectHint`
  (width/height in units), `priority` (higher kept under overflow).
* **`GridSolver.solve`** — pure function `(spec, columns, rows, metrics) ->
  GridSolution`. Deterministic: same inputs, same rects, every platform.
* **`GridSolution`** — `rects` in cells (+ `unitRects`, track sizes for
  tests), `dropped` items with reasons, per-axis `overflowUnits` /
  `trailingGapUnits`, and `hitTest(col, row)` (later items win overlaps,
  matching paint order).

## Solver passes (single deterministic pass per axis)

1. **Placement.** Explicit items are clamped into the template; auto items
   place first-fit row-major. Items that do not fit drop (`no-room`).
2. **Columns.** Fixed tracks take their size (clamped to min/max); `auto`
   tracks size from single-span item minimums, then spanning-item minimums
   spread evenly over the covered auto tracks; `weighted` tracks share the
   remaining space by weight — largest-remainder rounding, ties to the
   earlier track — then clamp to min/max (raises take from the largest
   surplus, lowers give to the smallest track with headroom).
3. **Rows.** The same pass, plus aspect hints: an item with an `aspectHint`
   in an `auto` row track sizes that track from its solved column width
   (`height = width / aspectHint`), clamped to the item/track bounds.
4. **Reconciliation.** If minimums overrun the terminal, auto then weighted
   tracks shrink toward their minimums (largest surplus first). Any
   remaining overrun drops the lowest-priority size-contributing item
   (later declarations first among equals) and re-solves; if the overrun is
   from the template alone it is reported in `overflowUnits` with rects
   truncated to the screen. **Rects are never negative and never extend
   past the terminal.**

## Consumers

* `tina_console`'s `ScreenLayout.fromSize` — the main chat screen
  (transcript, input row, status strip, split panes, menu box, sidebar) is
  solved through two nested grids, with the historical geometry kept as the
  spec's policy layer.
* `tina_chat_tui`'s floating image panels — right-anchored overlay column,
  each panel's row track sized from its image's aspect hint.
