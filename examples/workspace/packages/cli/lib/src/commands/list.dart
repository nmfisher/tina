/// `track list` — print one line per task.
library;

import 'package:core/core.dart';
import 'package:store/store.dart';

Future<int> listCommand(JsonFileStore store, List<String> args) async {
  final events = (await store.list()).unwrapOr(const []);
  final byTask = <String, TaskEvent>{};
  for (final event in events) {
    byTask[event.taskId] = event;
  }
  final sorted = byTask.keys.toList()..sort();
  for (final id in sorted) {
    final event = byTask[id]!;
    final state = event is TaskCompleted ? 'x' : ' ';
    final title = switch (event) {
      TaskCreated(:final title) => title,
      TaskRenamed(:final title) => title,
      _ => '(no title)',
    };
    print('[$state] $id  $title');
  }
  return 0;
}
