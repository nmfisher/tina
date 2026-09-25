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
      PlanItem('regex fix', state: PlanState.inProgress),
      PlanItem('later'),
      PlanItem('setup', state: PlanState.done),
    ]);
    expect(text(summary), 'plan: regex fix · 1/3 done');
  });

  test('without an active item, only the counts remain', () {
    final summary = PlanSummary([
      PlanItem('a', state: PlanState.done),
      PlanItem('b', state: PlanState.done),
    ]);
    expect(text(summary), 'plan: 2/2 done');
  });

  test('counts span children', () {
    final summary = PlanSummary([
      PlanItem(
        'parent',
        state: PlanState.inProgress,
        children: [
          PlanItem('sub', state: PlanState.done),
          PlanItem('open'),
        ],
      ),
      PlanItem('done root', state: PlanState.done),
    ]);
    expect(
      text(summary),
      'plan: parent · 2/4 done',
      reason: 'subtasks are plan work: done/total covers them',
    );
  });

  test('the label run is dim and the body unstyled', () {
    final summary = PlanSummary([PlanItem('a', state: PlanState.inProgress)]);
    final runs = renderer.render(summary, context).expand((l) => l.runs);
    expect(runs.first.text, 'plan: ');
    expect(runs.first.code, Theme.defaults().chat.dim);
    expect(runs.last.text, 'a · 0/1 done');
    expect(runs.last.code, isNull);
  });
}
