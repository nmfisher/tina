import 'package:tina_app/tina_app.dart';
import 'package:tina_console/tina_console.dart';

/// Strip renderer for a running background index: `indexing · 12/54` with a
/// spinner while the run is live. Pure function of the [IndexProgress] value;
/// the source declines when no run is active, so this only ever sees a
/// non-empty one.
class IndexingStatusRenderer extends Renderer<IndexProgress> {
  const IndexingStatusRenderer();

  static const _frames = ['|', '/', '-', '\\'];

  @override
  List<RenderLine> render(IndexProgress value, RenderContext context) {
    final dim = context.theme.chat.dim;
    final frame = _frames[context.animationFrame % _frames.length];
    // 0/0 is a run whose size is not announced yet — spin without counts
    // rather than showing a confusing zero total.
    final counts = value.total == 0 ? '' : ' · ${value.done}/${value.total}';
    return [
      RenderLine(
        animated: true,
        runs: [RenderRun('indexing $frame', dim), RenderRun(counts, null)],
      ),
    ];
  }
}
