import 'package:tina_console/tina_console.dart';

/// A status strip layout that honors plugin lines' alignment requests and
/// protects the important content under width pressure.
///
/// Policy (in order):
/// 1. Keep every right-aligned line (the token counter's slot); keep them in
///    order, as the strip supports a single right group.
/// 2. Keep the mode label, then left lines in registration order.
/// 3. When the joined width exceeds the strip, drop the LEFT lines from the
///    end backward — newest plugin status dies first — until the remainder
///    fits. The right group never shrinks until every left line is gone;
///    then the strip clips it.
///
/// Rendering styles are preserved: the layout returns the original lines
/// (minus dropped ones), so codes/bars flow to the painter unchanged.
class PriorityStatusLayout implements StatusLayout {
  const PriorityStatusLayout();

  @override
  List<RenderLine> arrange(StatusContent content, int width) {
    if (width <= 0) return const [];
    final right = content.lines
        .where((l) => l.align == StatusAlign.right)
        .toList();
    final left = <RenderLine>[
      if (content.modeLabel != null && content.modeLabel!.isNotEmpty)
        RenderLine(runs: [RenderRun(content.modeLabel!, '2')]),
      ...content.lines.where((l) => l.align != StatusAlign.right),
    ];
    final gap = (right.isEmpty || left.isEmpty) ? 0 : 2;
    final rightWidth = _joinedWidth(right);
    // Right group never shrinks until every left line is gone.
    var leftBudget = width - rightWidth - gap;
    if (leftBudget < 0) leftBudget = 0;
    // Drop the left lines from the end backward until what remains fits.
    final kept = <RenderLine>[];
    var used = 0;
    for (var i = 0; i < left.length; i++) {
      final line = left[i];
      final w = _lineWidth(line);
      final sep = used > 0 && w > 0 ? 5 : 0; // '  │  '
      if (used + sep + w > leftBudget) {
        // This line doesn't fit; everything after it is dropped too.
        break;
      }
      kept.add(line);
      used += sep + w;
      if (used >= leftBudget) break;
    }
    // A right group wider than the strip is clipped by the painter.
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
}
