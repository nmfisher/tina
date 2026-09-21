import 'package:logging/logging.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_engine/tina_engine.dart';

export 'package:tina_console/tina_console.dart'
    show Renderer, RenderContext, RenderLine, RenderRun;

final _log = Logger('tina.renderers');

/// Borrows live Renderer contributions from the existing plugin registry.
/// Nearest scope first, registration order within each scope, first non-null
/// result wins. The caller supplies the built-in fallback for its UI surface.
class Renderers {
  final PluginScope? scope;
  const Renderers([this.scope]);

  List<RenderLine> render<T extends Object>(
    T value,
    RenderContext context, {
    required Renderer<T> fallback,
  }) {
    for (var current = scope; current != null; current = current.parent) {
      if (!current.isAdmitting) continue;
      for (final contribution in current.contributions) {
        final renderer = contribution.contribution;
        if (renderer is! Renderer) continue;
        try {
          final lines = renderer.tryRender(value, context);
          if (lines != null) return lines;
        } catch (error) {
          // A presentation extension must not interrupt the agent/input loop.
          // Do not log the value or exception text (either may contain secrets).
          _log.warning(
            'Renderer ${contribution.id} failed '
            '(${error.runtimeType}); trying the next renderer.',
          );
        }
      }
    }
    return fallback.render(value, context) ?? const [];
  }
}
