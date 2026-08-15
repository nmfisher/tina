/// Task lifecycle events. Events are immutable facts; state is derived.
library;

/// Base class for everything that can happen to a task.
abstract final class TaskEvent {
  const TaskEvent({required this.taskId, required this.at});

  /// The task this event refers to.
  final String taskId;

  /// When the event occurred, in milliseconds since the epoch.
  final int at;

  /// Type tag used when (de)serializing — matches the concrete class name.
  String get type;

  Map<String, Object?> toJson() => {'type': type, 'taskId': taskId, 'at': at};

  static TaskEvent fromJson(Map<String, Object?> json) {
    final taskId = json['taskId']! as String;
    final at = json['at']! as int;
    return switch (json['type'] as String) {
      'TaskCreated' => TaskCreated(
        taskId: taskId,
        at: at,
        title: json['title']! as String,
      ),
      'TaskRenamed' => TaskRenamed(
        taskId: taskId,
        at: at,
        title: json['title']! as String,
      ),
      'TaskCompleted' => TaskCompleted(taskId: taskId, at: at),
      'TaskReopened' => TaskReopened(taskId: taskId, at: at),
      final unknown => throw FormatException('Unknown event type "$unknown"'),
    };
  }
}

final class TaskCreated extends TaskEvent {
  const TaskCreated({
    required super.taskId,
    required super.at,
    required this.title,
  });

  final String title;

  @override
  String get type => 'TaskCreated';

  @override
  Map<String, Object?> toJson() => {...super.toJson(), 'title': title};
}

final class TaskRenamed extends TaskEvent {
  const TaskRenamed({
    required super.taskId,
    required super.at,
    required this.title,
  });

  final String title;

  @override
  String get type => 'TaskRenamed';

  @override
  Map<String, Object?> toJson() => {...super.toJson(), 'title': title};
}

final class TaskCompleted extends TaskEvent {
  const TaskCompleted({required super.taskId, required super.at});

  @override
  String get type => 'TaskCompleted';
}

final class TaskReopened extends TaskEvent {
  const TaskReopened({required super.taskId, required super.at});

  @override
  String get type => 'TaskReopened';
}
