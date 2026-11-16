/// Exports the layout golden table as JSON for the wasm.dart host-side
/// parity test: every spec in tina_layout's battery plus resize sweeps,
/// with the expected solution records from the built-in solver. The Rust
/// test loads the built plugin component and replays the table through
/// the real Store + Val boundary; rects must agree on every entry.
library;

import 'dart:convert';
import 'dart:io';
import 'package:tina_layout/tina_layout.dart';

void main(List<String> args) {
  final cases = <Map<String, Object?>>[
    // -- The chat screen's actual grids -------------------------------
    LayoutWire.goldenCase('chat-split-100',
        _chatSplit(), columns: 100, rows: 24),
    LayoutWire.goldenCase('chat-split-120',
        _chatSplit(), columns: 120, rows: 30),
    LayoutWire.goldenCase('chat-split-tie-110',
        _chatSplit(), columns: 110, rows: 24),
    LayoutWire.goldenCase('chat-split-clamped-50',
        _chatSplit(), columns: 50, rows: 24),
    LayoutWire.goldenCase('chat-split-clamped-55',
        _chatSplit(), columns: 55, rows: 24),
    LayoutWire.goldenCase('chat-half-units-24',
        _chatStack(), columns: 80, rows: 24),
    LayoutWire.goldenCase('chat-half-units-25',
        _chatStack(), columns: 80, rows: 25),
    LayoutWire.goldenCase('chat-half-units-4',
        _chatStack(), columns: 80, rows: 4),
    LayoutWire.goldenCase('sidebar-body',
        _sidebarBody(), columns: 80, rows: 24),
    LayoutWire.goldenCase('sidebar-body-16',
        _sidebarBody(), columns: 16, rows: 12),
    LayoutWire.goldenCase('interior-grid',
        _interior(), columns: 78, rows: 23),
    LayoutWire.goldenCase('interior-grid-63',
        _interior(), columns: 63, rows: 22),

    // -- Edges ----------------------------------------------------------
    LayoutWire.goldenCase(
        'auto-mins',
        const GridSpec(
          columns: [GridTrack.auto(), GridTrack.auto()],
          rows: [GridTrack.weighted(1)],
          items: [
            GridItem(
                id: 'a',
                minWidthUnits: 10,
                column: TrackSpan.at(0),
                row: TrackSpan.at(0)),
            GridItem(
                id: 'b',
                minWidthUnits: 5,
                column: TrackSpan.at(1),
                row: TrackSpan.at(0)),
          ],
        ),
        columns: 40,
        rows: 10),
    LayoutWire.goldenCase(
        'spanning-min',
        const GridSpec(
          columns: [GridTrack.auto(), GridTrack.auto()],
          rows: [GridTrack.weighted(1)],
          items: [
            GridItem(
                id: 'a',
                minWidthUnits: 2,
                column: TrackSpan.at(0),
                row: TrackSpan.at(0)),
            GridItem(
                id: 'wide',
                minWidthUnits: 16,
                column: TrackSpan.at(0, span: 2),
                row: TrackSpan.at(0)),
          ],
        ),
        columns: 40,
        rows: 10),
    LayoutWire.goldenCase(
        'overflow-drops',
        const GridSpec(
          columns: [GridTrack.auto(), GridTrack.auto(), GridTrack.auto()],
          rows: [GridTrack.weighted(1)],
          items: [
            GridItem(
                id: 'chat',
                priority: 2,
                minWidthUnits: 6,
                column: TrackSpan.at(0),
                row: TrackSpan.at(0)),
            GridItem(
                id: 'p1',
                priority: 1,
                minWidthUnits: 6,
                column: TrackSpan.at(1),
                row: TrackSpan.at(0)),
            GridItem(
                id: 'p0',
                priority: 0,
                minWidthUnits: 6,
                column: TrackSpan.at(2),
                row: TrackSpan.at(0)),
          ],
        ),
        columns: 10,
        rows: 10),
    LayoutWire.goldenCase(
        'zero-terminal',
        const GridSpec(
          columns: [GridTrack.fixed(1), GridTrack.weighted(1)],
          rows: [GridTrack.fixed(0.5), GridTrack.weighted(1)],
          items: [
            GridItem(
                id: 'only',
                column: TrackSpan.at(1),
                row: TrackSpan.at(1)),
          ],
        ),
        columns: 0,
        rows: 0),
    LayoutWire.goldenCase(
        'one-by-one',
        const GridSpec(
          columns: [GridTrack.fixed(1), GridTrack.weighted(1)],
          rows: [GridTrack.fixed(0.5), GridTrack.weighted(1)],
          items: [
            GridItem(
                id: 'only',
                column: TrackSpan.at(1),
                row: TrackSpan.at(1)),
          ],
        ),
        columns: 1,
        rows: 1),

    // -- Aspect + auto-flow + metrics ------------------------------------
    LayoutWire.goldenCase(
        'aspect-overlay',
        GridSpec(
          columns: const [
            GridTrack.weighted(3),
            GridTrack.weighted(2, minUnits: 24, maxUnits: 64),
          ],
          rows: const [GridTrack.auto()],
          items: [
            const GridItem(
              id: 'panel',
              column: TrackSpan.at(1),
              row: TrackSpan.at(0),
              aspectHint: 4,
            ),
          ],
        ),
        columns: 120,
        rows: 24),
    LayoutWire.goldenCase(
        'auto-flow',
        const GridSpec(
          columns: [GridTrack.weighted(1), GridTrack.weighted(1)],
          rows: [GridTrack.weighted(1), GridTrack.weighted(1)],
          items: [
            GridItem(id: 'a'),
            GridItem(id: 'b', column: TrackSpan.span(2)),
            GridItem(id: 'c'),
          ],
        ),
        columns: 20,
        rows: 20),
    LayoutWire.goldenCase(
        'square-metrics',
        const GridSpec(
          columns: [GridTrack.weighted(1)],
          rows: [GridTrack.fixed(1), GridTrack.weighted(1), GridTrack.fixed(1)],
          items: [
            GridItem(
                id: 'mid', column: TrackSpan.at(0), row: TrackSpan.at(1)),
          ],
        ),
        columns: 10,
        rows: 7,
        metrics: CellMetrics.fromPixels(cellWidthPx: 8, cellHeightPx: 8)),
    LayoutWire.goldenCase(
        'odd-metrics',
        const GridSpec(
          columns: [GridTrack.fixed(3), GridTrack.weighted(1)],
          rows: [GridTrack.weighted(1)],
          items: [
            GridItem(
                id: 'body', column: TrackSpan.at(1), row: TrackSpan.at(0)),
          ],
        ),
        columns: 30,
        rows: 19,
        metrics: CellMetrics.fromPixels(cellWidthPx: 8, cellHeightPx: 19)),

    // -- Resize sweep (a representative slice) ---------------------------
    for (var i = 0; i < 12; i++)
      LayoutWire.goldenCase(
          'resize-sweep-$i', _sidebarBody(), columns: 40 + i * 11, rows: 8 + i * 3),
  ];

  final json = const JsonEncoder.withIndent('  ')
      .convert({'cases': cases.map(_jsonSafe).toList()});
  stdout.write(json);
}

/// JSON-safe doubles (no Infinity on the wire: unbounded track maximums
/// are `null` by construction; NaN never occurs in solved output).
Map<String, Object?> _jsonSafe(Map<String, Object?> value) => value;

GridSpec _chatSplit() => const GridSpec(
      columns: [
        GridTrack.weighted(65, minUnits: 30),
        GridTrack.weighted(35, minUnits: 20),
      ],
      rows: [GridTrack.weighted(1)],
      items: [
        GridItem(
            id: 'chat', column: TrackSpan.at(0), row: TrackSpan.at(0)),
        GridItem(
            id: 'info', column: TrackSpan.at(1), row: TrackSpan.at(0)),
      ],
    );

GridSpec _chatStack() => const GridSpec(
      columns: [GridTrack.weighted(1)],
      rows: [
        GridTrack.fixed(0.5),
        GridTrack.weighted(1),
        GridTrack.fixed(0.5),
        GridTrack.fixed(0.5),
        GridTrack.fixed(0.5),
      ],
      items: [
        GridItem(id: 'top', column: TrackSpan.at(0), row: TrackSpan.at(0)),
        GridItem(
            id: 'transcript', column: TrackSpan.at(0), row: TrackSpan.at(1)),
        GridItem(id: 'input', column: TrackSpan.at(0), row: TrackSpan.at(2)),
        GridItem(id: 'bottom', column: TrackSpan.at(0), row: TrackSpan.at(3)),
        GridItem(id: 'strip', column: TrackSpan.at(0), row: TrackSpan.at(4)),
      ],
    );

GridSpec _sidebarBody() => const GridSpec(
      columns: [
        GridTrack.fixed(3, minUnits: 3),
        GridTrack.weighted(1),
      ],
      rows: [
        GridTrack.fixed(0.5),
        GridTrack.weighted(1),
        GridTrack.fixed(0.5),
      ],
      items: [
        GridItem(
            id: 'sidebar',
            column: TrackSpan.at(0),
            row: TrackSpan.at(0, span: 3)),
        GridItem(id: 'header', column: TrackSpan.at(1), row: TrackSpan.at(0)),
        GridItem(id: 'body', column: TrackSpan.at(1), row: TrackSpan.at(1)),
        GridItem(id: 'footer', column: TrackSpan.at(1), row: TrackSpan.at(2)),
      ],
    );

GridSpec _interior() => const GridSpec(
      columns: [
        GridTrack.fixed(1),
        GridTrack.weighted(1),
        GridTrack.fixed(1),
      ],
      rows: [
        GridTrack.fixed(0.5),
        GridTrack.weighted(1),
        GridTrack.fixed(0.5),
        GridTrack.fixed(0.5),
      ],
      items: [
        GridItem(
            id: 'content', column: TrackSpan.at(1), row: TrackSpan.at(1)),
        GridItem(id: 'input', column: TrackSpan.at(1), row: TrackSpan.at(2)),
      ],
    );
