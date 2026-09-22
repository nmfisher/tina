import 'package:tina_app/tina_app.dart';
import 'package:tina_console/tina_console.dart';
import '../frontend/renderers.dart';

class IntentStatusRenderer extends Renderer<IntentStatus> {
  const IntentStatusRenderer();
  static const _frames = ['|', '/', '-', '\\'];
  @override
  List<RenderLine> render(IntentStatus value, RenderContext context) {
    final text = switch (value.phase) {
      IntentPhase.checking =>
        'classifying… ${_frames[context.animationFrame % _frames.length]}',
      IntentPhase.unavailable => 'intent classification unavailable',
      IntentPhase.cancelled => 'intent classification cancelled',
      IntentPhase.ready => switch (value.result?.type) {
        IntentType.projectQuestion => 'project question',
        IntentType.agentInstruction => 'agent instruction',
        null => 'intent unclear',
      },
    };
    return [
      RenderLine(
        animated: value.phase == IntentPhase.checking,
        runs: [RenderRun('Last input: $text', context.theme.chat.dim)],
      ),
    ];
  }
}
