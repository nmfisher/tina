import 'src/state.dart';
export 'src/state.dart';

/// The queue as the plugin holds it between entries: the entry list
/// replayed. The log is the truth; this is the running session's reading
/// of it, kept current by subscribing to the loop.
class TaskState {
  final List<TaskEntryItem> items;

  TaskState({required List<TaskEntryItem> items})
      : items = List.unmodifiable(items);

  bool get isEmpty => items.isEmpty;

  /// The in-progress task, or null when none is.
  TaskEntryItem? get current {
    for (final item in items) {
      if (item.state == 'in_progress') return item;
    }
    return null;
  }

  List<TaskEntryItem> get pending =>
      items.where((i) => i.state == 'pending').toList();

  TaskEntryItem? get next {
    for (final item in items) {
      if (item.state == 'pending') return item;
    }
    return null;
  }
}

/// Read-only tasks data; readers own only their subscriptions.
abstract interface class TaskObservation {
  TaskState get state;
  String? get unavailableReason;
  void Function() listen(void Function() changed);
}
