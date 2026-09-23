import 'package:tina_app/tina_app.dart';
import 'package:tina_console/tina_console.dart';

/// Renders the session's token spend onto the status strip: `Σ 12,345` when
/// unbounded, `Σ 12,345 / 30k · 41%` against a cap, `+~2.1k est` when
/// failed-attempt bookings exist, `TRIPPED` in red once the ceiling is
/// crossed. Right-aligned: the strip anchors it to the row's right edge so
/// the mode label and plugin status keep the left.
class TokenUsageRenderer extends Renderer<TokenUsageSummary> {
  const TokenUsageRenderer();

  @override
  List<RenderLine> render(TokenUsageSummary value, RenderContext context) {
    final runs = <RenderRun>[];
    final theme = context.theme.chat;
    final fraction = value.capFraction;
    if (value.tripped) {
      runs.add(RenderRun('SPEND LIMIT TRIPPED', theme.red));
      return [
        RenderLine(align: StatusAlign.right, runs: runs),
      ];
    }
    runs.add(RenderRun('Σ ${_format(value.totalTokens)}', theme.dim));
    if (value.estimatedTokens > 0) {
      runs.add(RenderRun(
          ' +~${_format(value.estimatedTokens)} est', theme.yellow));
    }
    final cap = value.cap;
    if (cap != null) {
      final pct = ((fraction ?? 0) * 100).round();
      final color = _capColor(fraction, theme);
      runs.add(RenderRun(' / ${_format(cap)} · $pct%', color));
    }
    return [
      RenderLine(align: StatusAlign.right, runs: runs),
    ];
  }

  String _capColor(double? fraction, ChatTheme theme) {
    if (fraction == null) return theme.dim;
    if (fraction >= 0.9) return theme.red;
    if (fraction >= 0.75) return theme.yellow;
    return theme.dim;
  }

  String _format(int n) {
    final s = n.toString();
    final buf = StringBuffer();
    for (var i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) buf.write(',');
      buf.write(s[i]);
    }
    return buf.toString();
  }
}
