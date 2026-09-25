import 'package:tina_app/tina_app.dart';
import 'package:tina_console/tina_console.dart';

/// Strip renderer for the focused conversation's goal, e.g.
/// `goal: fix the login race` (`✓` when the judge marked it achieved, `?`
/// when uncertain). Pure function of the [GoalSummary] value; the source
/// declines empty goals, so this only ever sees a non-empty one.
class GoalStatusRenderer extends Renderer<GoalSummary> {
  const GoalStatusRenderer();

  @override
  List<RenderLine> render(GoalSummary value, RenderContext context) {
    final dim = context.theme.chat.dim;
    final parts = [
      value.summary,
      if (value.isUncertain && value.evidence.isNotEmpty) value.evidence,
    ];
    return [
      RenderLine(
        runs: [RenderRun('goal: ', dim), RenderRun(parts.join(' · '), null)],
      ),
    ];
  }
}
