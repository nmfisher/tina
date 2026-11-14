import 'package:tina_layout/tina_layout.dart' hide FocusLayoutStrategy;
import 'package:tina_layout_plugins/src/plugin/strategies.dart';
import 'package:test/test.dart';

/// The differential heart: the ENTIRE golden battery runs through the
/// plugin path (spec → wire records → solve → wire records → solution —
/// byte-for-byte the Store-boundary round trip) and must produce rects
/// identical to the core solver. `tina/layout-focus` then proves
/// swappability by disagreeing on purpose, and the chat screen pins the
/// visible difference.
void main() {
  final cases = <(String, GridSpec, int, int, CellMetrics)>[
    ('chat-split-100', _chatSplit(), 100, 24, CellMetrics.standard),
    ('chat-split-120', _chatSplit(), 120, 30, CellMetrics.standard),
    ('chat-split-tie-110', _chatSplit(), 110, 24, CellMetrics.standard),
    ('chat-split-clamped-50', _chatSplit(), 50, 24, CellMetrics.standard),
    ('chat-split-clamped-55', _chatSplit(), 55, 24, CellMetrics.standard),
    ('chat-half-units-24', _chatStack(), 80, 24, CellMetrics.standard),
    ('chat-half-units-25', _chatStack(), 80, 25, CellMetrics.standard),
    ('chat-half-units-4', _chatStack(), 80, 4, CellMetrics.standard),
    ('sidebar-body-80', _sidebarBody(), 80, 24, CellMetrics.standard),
    ('sidebar-body-16', _sidebarBody(), 16, 12, CellMetrics.standard),
    ('interior-78', _interior(), 78, 23, CellMetrics.standard),
    ('zero-terminal', _sidebarBody(), 0, 0, CellMetrics.standard),
    ('one-by-one', _sidebarBody(), 1, 1, CellMetrics.standard),
    (
      'square-metrics',
      _interior(),
      10,
      7,
      CellMetrics.fromPixels(cellWidthPx: 8, cellHeightPx: 8),
    ),
    (
      'odd-metrics',
      _interior(),
      30,
      19,
      CellMetrics.fromPixels(cellWidthPx: 8, cellHeightPx: 19),
    ),
    ('aspect-overlay', _aspectOverlay(), 120, 24, CellMetrics.standard),
    ('auto-flow', _autoFlow(), 20, 20, CellMetrics.standard),
    ('overflow-drops', _overflowDrops(), 10, 10, CellMetrics.standard),
    ...[
      for (var i = 0; i < 12; i++)
        (
          'resize-sweep-$i',
          _sidebarBody(),
          40 + i * 11,
          8 + i * 3,
          CellMetrics.standard
        ),
    ],
    // Odd-terminal sweep: every size class the solver test battery covers.
    ...[
      for (var w = 1; w <= 130; w += 13)
        (
          'width-sweep-$w',
          _chatSplit(),
          w,
          24,
          CellMetrics.standard
        ),
    ],
    ...[
      for (var h = 1; h <= 40; h += 7)
        (
          'height-sweep-$h',
          _chatStack(),
          80,
          h,
          CellMetrics.standard
        ),
    ],
  ];

  test(
      'differential goldens: the plugin path is byte-identical to the core '
      'solver across the whole battery',
      () {
    const strategy = SolverLayoutStrategy();
    for (final (name, spec, columns, rows, metrics) in cases) {
      final viaPlugin = strategy.solveSpec(spec,
          columns: columns, rows: rows, metrics: metrics);
      final viaCore = GridSolver.solve(spec,
          columns: columns, rows: rows, metrics: metrics);
      expect(viaPlugin.rects, viaCore.rects,
          reason: '$name: rects diverged');
      expect(viaPlugin.columnTrackSizes, viaCore.columnTrackSizes,
          reason: '$name: column tracks diverged');
      expect(viaPlugin.rowTrackSizes, viaCore.rowTrackSizes,
          reason: '$name: row tracks diverged');
      expect(viaPlugin.dropped.map((d) => '${d.id}:${d.reason}'),
          viaCore.dropped.map((d) => '${d.id}:${d.reason}'),
          reason: '$name: drops diverged');
      expect(viaPlugin.overflowUnitsX, viaCore.overflowUnitsX,
          reason: '$name: overflow x diverged');
      expect(viaPlugin.overflowUnitsY, viaCore.overflowUnitsY,
          reason: '$name: overflow y diverged');
      expect(viaPlugin.trailingGapUnitsX, viaCore.trailingGapUnitsX,
          reason: '$name: gap x diverged');
      expect(viaPlugin.trailingGapUnitsY, viaCore.trailingGapUnitsY,
          reason: '$name: gap y diverged');
      expect(LayoutWire.solution(viaPlugin), LayoutWire.solution(viaCore),
          reason: '$name: the wire records diverged');
    }
  });

  test('focus disagrees on purpose (equal-share weighted tracks)', () {
    const focus = FocusLayoutStrategy();
    for (final (name, spec, columns, rows, metrics) in cases) {
      final viaFocus =
          focus.solveSpec(spec, columns: columns, rows: rows, metrics: metrics);
      final viaCore = GridSolver.solve(spec,
          columns: columns, rows: rows, metrics: metrics);
      // Wherever weighted tracks with distinct declared weights share a
      // remainder wide enough to distribute, focus MUST differ
      // (65/35 -> 50/50). At clamped sizes the minimums bind and both
      // strategies agree - that is the contract, not a failure.
      final weighted = spec.columns
          .where((t) => t.kind == TrackKind.weighted)
          .toList();
      final distinctWeights =
          weighted.map((t) => t.weight).toSet().length > 1;
      final roomy = viaCore.columnTrackSizes
          .any((size) => size > (weighted.isEmpty ? 0 : weighted.first.minUnits));
      if (weighted.length > 1 && distinctWeights && roomy) {
        expect(viaFocus.columnTrackSizes, isNot(equals(viaCore.columnTrackSizes)),
            reason: '$name: focus must be visibly different');
      }
      for (final rect in viaFocus.rects.values) {
        expect(rect.width, greaterThanOrEqualTo(0));
        expect(rect.height, greaterThanOrEqualTo(0));
      }
    }
    expect(
        focus
            .solveSpec(_chatSplit(), columns: 100, rows: 24)
            .columnTrackSizes,
        [50, 50]);
  });

  test('swap: install focus, the chat screen changes; uninstall restores',
      () {
    // The chat screen's split geometry, mirroring ScreenLayout's template.
    GridSolution outerChat(int width) =>
        GridSolver.solve(_chatSplit(), columns: width, rows: 24);

    addTearDown(LayoutStrategies.uninstall);
    expect(LayoutStrategies.installed, isNull,
        reason: 'default: the built-in solver');

    LayoutStrategies.install(const FocusLayoutStrategy());
    final focused = LayoutStrategies.solve(_chatSplit(),
        columns: 100, rows: 24);
    expect(
        focused.rects['chat']!.width, lessThan(outerChat(100).rects['chat']!.width),
        reason: 'the chat pane visibly narrows (65 -> 50 columns)');

    LayoutStrategies.uninstall();
    final restored = LayoutStrategies.solve(_chatSplit(),
        columns: 100, rows: 24);
    expect(restored.rects, outerChat(100).rects,
        reason: 'uninstall returns the default byte-for-byte');
  });
}

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

GridSpec _aspectOverlay() => const GridSpec(
      columns: [
        GridTrack.weighted(3),
        GridTrack.weighted(2, minUnits: 24, maxUnits: 64),
      ],
      rows: [GridTrack.auto()],
      items: [
        GridItem(
            id: 'panel',
            column: TrackSpan.at(1),
            row: TrackSpan.at(0),
            aspectHint: 4),
      ],
    );

GridSpec _autoFlow() => const GridSpec(
      columns: [GridTrack.weighted(1), GridTrack.weighted(1)],
      rows: [GridTrack.weighted(1), GridTrack.weighted(1)],
      items: [
        GridItem(id: 'a'),
        GridItem(id: 'b', column: TrackSpan.span(2)),
        GridItem(id: 'c'),
      ],
    );

GridSpec _overflowDrops() => const GridSpec(
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
    );
