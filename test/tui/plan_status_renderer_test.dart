import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';
import 'package:tina_app/tina_app.dart';
import 'package:tina/tui/plan_status_renderer.dart';

/// Pure-data renderer: no streams, no scopes — only formats a [PlanSummary]
/// into strip lines.
void main() {
  const renderer = PlanStatusRenderer();
  const context = RenderContext(width: 80, theme: Theme.defaults());

  String text(PlanSummary value) => renderer
      .render(value, context)
      .expand((l) => l.runs)
      .map((r) => r.text)
      .join();

  test('renders the active item plus done counts', () {
    final summary = PlanSummary([
      (text: 'regex fix', state: PlanState.inProgress),
      (text: 'later', state: PlanState.pending),
      (text: 'setup', state: PlanState.done),
    ]);
    expect(text(summary), 'plan: regex fix · 1/3 done');
  });

  test('without an active item, only the counts remain', () {
    final summary = PlanSummary([
      (text: 'a', state: PlanState.done),
      (text: 'b', state: PlanState.done),
    ]);
    expect(text(summary), 'plan: 2/2 done');
  });

  test('the label run is dim and the body unstyled', () {
    final summary = PlanSummary([
      (text: 'a', state: PlanState.inProgress),
    ]);
    final runs = renderer.render(summary, context).expand((l) => l.runs);
    expect(runs.first.text, 'plan: ');
    expect(runs.first.code, Theme.defaults().chat.dim);
    expect(runs.last.text, 'a · 0/1 done');
    expect(runs.last.code, isNull);
  });
}
