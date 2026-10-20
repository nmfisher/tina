import 'package:tina_console/tina_console.dart';
import 'package:tina_tasks/tina_tasks.dart';

import 'tasks_overview_panel.dart';

/// Console contribution that hosts a [TaskOverviewPanel] for one attachment.
/// It subscribes to the task observation and repaints the panel on changes.
final class TaskOverviewView implements ConsoleContribution {
  TaskOverviewView(this.tasks);
  final TaskObservation tasks;
  ConsoleContext? _console;
  TaskOverviewPanel? panel;
  void Function()? _release;

  @override
  void attachConsole(ConsoleContext context) {
    detachConsole();
    _console = context;
    final inspector = panel = TaskOverviewPanel(tasks: tasks, context: context);
    final release = tasks.listen(repaintConsole);
    _release = context.own(() {
      release();
      inspector.dispose();
      if (identical(panel, inspector)) panel = null;
    });
    inspector.start();
  }

  @override
  void repaintConsole() => panel?.refresh();

  @override
  void detachConsole() {
    _release?.call();
    _release = null;
    _console?.chat.repaint();
    _console = null;
  }
}
