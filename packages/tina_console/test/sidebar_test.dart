import 'package:test/test.dart';
import 'package:tina_console/tina_console.dart';

void main() {
  test(
      'plugin panels share rows, yield space when hidden, and relayout on resize',
      () async {
    var chat = const Rect(row: 1, col: 0, width: 80, height: 16);
    var paints = 0;
    final layout = SidebarLayout(() => chat);
    final plan = layout.register(() => paints++, priority: 10)
      ..requestSize(height: 12);
    final classification = layout.register(() => paints++, priority: 20)
      ..requestSize(height: 8, width: 64);
    await pumpEventQueue();
    expect(plan.bounds.bottom, lessThan(classification.bounds.row));
    expect(plan.bounds.height, 8);
    expect(classification.bounds.height, 8);
    expect(classification.bounds.width, 64);
    final previousPaints = paints;
    classification.requestSize(height: 8, width: 64);
    await pumpEventQueue();
    expect(paints, previousPaints);
    classification.requestSize(height: 0);
    expect(plan.bounds.height, 12);
    chat = const Rect(row: 1, col: 0, width: 12, height: 4);
    classification.requestSize(height: 10, focused: true);
    expect(classification.bounds.height, 4);
    expect(classification.bounds.width, 12);
    expect(plan.bounds.isEmpty, true);
    classification.dispose();
    expect(plan.bounds.height, 4);
    plan.dispose();
    expect(layout.isEmpty, true);
  });
}
