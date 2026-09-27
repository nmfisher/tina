/// The status strip: a pure function from a small value to rows.
///
/// [StatusStripState] is the brief's "small state value"; [statusStripRows]
/// mirrors `tina_console`'s `StatusLayout` contract (pure data in, rows out)
/// and the strip's painter accepts its output lines unchanged via
/// `Screen.setStatusLines`. Under width pressure the mode label survives and
/// plugin lines drop from the end — the same policy as the app's
/// `PriorityStatusLayout`. A plugin can replace the arrangement later by
/// registering a `StatusLayout`; the painter, not this function, owns where
/// the strip sits.
library;

import 'package:tina_console/tina_console.dart';

/// Everything the strip could show, at a point in time. Pure data.
class StatusStripState {
  /// The host-owned permission-mode label (`mode: ask`), or null.
  final String? modeLabel;

  /// Plugin status lines in registration order; each may request the
  /// right-aligned slot (`RenderLine(align: StatusAlign.right)`).
  final List<RenderLine> lines;

  const StatusStripState({this.modeLabel, this.lines = const []});
}

/// Arrange [state] into the rows the strip paints, within [width] columns.
///
/// Policy: left group is the mode label then plugin lines joined `  │  `;
/// the right group keeps its slot and never shrinks until every left line is
/// gone; left lines drop from the end backward.
List<RenderLine> statusStripRows(StatusStripState state, int width) {
  if (width <= 0) return const [];
  final right = state.lines
      .where((l) => l.align == StatusAlign.right)
      .toList(growable: false);
  final left = <RenderLine>[
    if (state.modeLabel != null && state.modeLabel!.isNotEmpty)
      RenderLine(runs: [RenderRun(state.modeLabel!, '2')]),
    ...state.lines.where((l) => l.align != StatusAlign.right),
  ];
  final gap = (right.isEmpty || left.isEmpty) ? 0 : 2;
  var budget = width - _joinedWidth(right) - gap;
  if (budget < 0) budget = 0;
  final kept = <RenderLine>[];
  var used = 0;
  for (final line in left) {
    final w = _lineWidth(line);
    final sep = used > 0 && w > 0 ? 5 : 0; // '  │  '
    if (used + sep + w > budget) break;
    kept.add(line);
    used += sep + w;
    if (used >= budget) break;
  }
  return [...kept, ...right];
}

int _joinedWidth(List<RenderLine> lines) {
  var w = 0;
  var first = true;
  for (final line in lines) {
    final lw = _lineWidth(line);
    if (lw == 0) continue;
    w += (first ? 0 : 5) + lw;
    first = false;
  }
  return w;
}

int _lineWidth(RenderLine line) {
  var w = 0;
  for (final run in line.runs) {
    w += visibleWidth(run.text);
  }
  return w;
}
