import 'package:tina_app/tina_app.dart';
import 'package:tina_console/tina_console.dart';

/// Strip renderer for the focused conversation's plan, e.g.
/// `plan: regex fix · 2/5 done`. Pure function of the [PlanSummary] value;
/// the source declines empty plans, so this only ever sees a non-empty one.
class PlanStatusRenderer extends Renderer<PlanSummary> {
  const PlanStatusRenderer();

  @override
  List<RenderLine> render(PlanSummary value, RenderContext context) {
    final dim = context.theme.chat.dim;
    final parts = [
      if (value.active != null) value.active!,
      '${value.done}/${value.total} done',
    ];
    return [
      RenderLine(
        runs: [
          RenderRun('plan: ', dim),
          RenderRun(parts.join(' · '), null),
        ],
      ),
    ];
  }
}
