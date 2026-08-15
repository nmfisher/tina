/// Aggregates an event stream into human-readable counts.
library;

import 'package:core/core.dart';
import 'package:store/store.dart';

/// Reduced statistics over a set of tasks.
final class TaskSummary {
  final int total;
  final int open;
  final int completed;

  const TaskSummary({
    required this.total,
    required this.open,
    required this.completed,
  });

  @override
  String toString() =>
      'TaskSummary(total: $total, open: $open, completed: $completed)';
}

/// Folds a [Repository] of events into a [TaskSummary].
///
/// Uses the store's query helpers rather than raw iteration so the
/// summary reflects the same filtering path users see.
final class SummaryReporter {
  final Repository<TaskEvent> repository;

  const SummaryReporter(this.repository);

  Future<TaskSummary> summarize({Filter<TaskEvent>? only}) async {
    final events = (await repository.list()).unwrapOr(const []);
    final scoped = only == null ? events : whereFilter(events, only);
    final byTask = <String, TaskEvent?>{};
    for (final event in scoped) {
      final existing = byTask[event.taskId];
      if (existing == null || event.at >= existing.at) {
        byTask[event.taskId] = event;
      }
    }
    var completed = 0;
    for (final latest in byTask.values) {
      if (latest is TaskCompleted) completed++;
    }
    return TaskSummary(
      total: byTask.length,
      open: byTask.length - completed,
      completed: completed,
    );
  }
}
