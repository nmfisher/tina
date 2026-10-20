import 'package:tina_engine_2/tina_engine_2.dart';

/// One task in the session's queue: a stable id, a short title, an
/// optional summary and a state word. Flat — a queue has no nesting; the
/// nesting belongs to the plan of the *current* task.
final class TaskEntryItem {
  /// The state words: the same vocabulary the tool schemas spell.
  static const stateWords = ['pending', 'in_progress', 'done', 'skipped'];
  static const maxTextLength = 240;
  static const maxSummaryLength = 2000;

  final String id;
  final String text;
  final String summary;
  final String state;

  const TaskEntryItem(
      {required this.id, required this.text, this.summary = '', required this.state});

  /// The state word for [state], validated before an entry carries it.
  /// Throws on anything else — a state no tool ever wrote must not
  /// silently become `pending`.
  static String validateState(String state) {
    if (!stateWords.contains(state)) {
      throw FormatException(
          'task state must be one of ${stateWords.join(", ")}');
    }
    return state;
  }

  TaskEntryItem copyWith({String? state, String? summary}) => TaskEntryItem(
      id: id,
      text: text,
      state: state ?? this.state,
      summary: summary ?? this.summary);

  @override
  bool operator ==(Object other) =>
      other is TaskEntryItem &&
      id == other.id &&
      text == other.text &&
      summary == other.summary &&
      state == other.state;

  @override
  int get hashCode => Object.hash(id, text, summary, state);

  @override
  String toString() => 'TaskEntryItem($id, $state, $text)';
}

/// The session's task queue changed: this entry **is** the queue, the
/// complete ordered list carried forward — the latest one in the log
/// wins, and a resume derives from it the same way the running session
/// does. Nothing else about a queue is derivable (the user's wording, the
/// order they chose, which task the agent is on), which is why the state
/// itself is logged rather than recomputed.
///
/// The shape is deliberately structured — items with ids and state words,
/// not one text blob: the prompt section, the query tool and an auditor
/// all read the same structured fact, and the at-most-one-in-progress
/// rule is checkable against the entry instead of trusted from the writer.
final class TaskQueueEntry extends PluginStateEntry {
  static bool matches(SessionEntry entry) =>
      entry is PluginStateEntry &&
      entry.pluginId == 'tina/tasks' &&
      entry.stateKey == 'queue';
  static TaskQueueEntry decode(PluginStateEntry entry) {
    if (!matches(entry) || entry.schemaVersion != 1)
      throw FormatException(
          'Unsupported tina/tasks state version ${entry.schemaVersion}');
    return fromJson(
        entry.value ?? {'items': const []}, entry.at, entry.seq);
  }

  static const kindName = 'task_queue';

  /// The complete item list this entry installs. Empty list = queue cleared.
  final List<TaskEntryItem> items;

  final String at;

  const TaskQueueEntry({required this.items, this.at = '', super.seq = 0});

  @override
  TaskQueueEntry withSeq(int newSeq) =>
      TaskQueueEntry(items: items, at: at, seq: newSeq);

  @override
  String get pluginId => 'tina/tasks';
  @override
  String get stateKey => 'queue';
  @override
  int get schemaVersion => 1;

  @override
  Map<String, dynamic> get value => {
        'items': [for (final i in items) _itemToJson(i)],
      };

  static Map<String, dynamic> _itemToJson(TaskEntryItem item) => {
        'id': item.id,
        'text': item.text,
        'state': item.state,
        if (item.summary.isNotEmpty) 'summary': item.summary,
      };

  /// The item cap a decoded entry enforces — a corrupt row is a reader
  /// error, not a queue. The plugin's store applies the same cap before
  /// anything is appended.
  static const maxItems = 64;

  /// Strict-but-bounded decode: unknown states throw (no tool ever wrote
  /// them), duplicate ids throw (a queue cannot address itself), and the
  /// item cap holds.
  static TaskQueueEntry fromJson(
    Map<String, dynamic> j,
    String at,
    int seq,
  ) {
    final rawItems = j['items'];
    if (rawItems is! List) {
      throw const FormatException('task_queue requires an items array');
    }
    if (rawItems.length > maxItems) {
      throw const FormatException('task_queue exceeds the item cap');
    }
    final items = <TaskEntryItem>[];
    final ids = <String>{};
    for (final raw in rawItems) {
      if (raw is! Map) {
        throw const FormatException('task item must be an object');
      }
      final item = _itemFromJson(Map<String, dynamic>.from(raw));
      if (!ids.add(item.id)) {
        throw FormatException('duplicate task id: ${item.id}');
      }
      items.add(item);
    }
    return TaskQueueEntry(items: items, at: at).withSeq(seq);
  }

  static TaskEntryItem _itemFromJson(Map<String, dynamic> j) {
    final id = j['id'];
    final text = j['text'];
    final state = j['state'];
    final summary = j.containsKey('summary') ? j['summary'] : '';
    if (id is! String || id.isEmpty) {
      throw const FormatException('task item requires a non-empty id');
    }
    if (text is! String || text.trim().isEmpty) {
      throw const FormatException('task item requires non-empty text');
    }
    if (text.length > TaskEntryItem.maxTextLength) {
      throw const FormatException(
          'task item text exceeds ${TaskEntryItem.maxTextLength} chars');
    }
    if (summary is! String || summary.length > TaskEntryItem.maxSummaryLength) {
      throw const FormatException(
          'task item summary must be a string of at most '
          '${TaskEntryItem.maxSummaryLength} chars');
    }
    return TaskEntryItem(
        id: id,
        text: text,
        state: TaskEntryItem.validateState(state as String? ?? 'pending'),
        summary: summary);
  }

  @override
  bool operator ==(Object other) =>
      other is TaskQueueEntry && _listEquals(items, other.items) && at == other.at;

  @override
  int get hashCode => Object.hash(Object.hashAll(items), at);

  @override
  String toString() => 'TaskQueue(${items.length} items)';
}

bool _listEquals(List<TaskEntryItem> a, List<TaskEntryItem> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The queue as a derivation reports it: the entry's items plus the
/// derived answers (which task is current, the counts) the prompt section
/// and a query tool want. Value type; [TaskQueueEntry] is the truth, this
/// is its reading.
final class SessionTaskQueue {
  final List<TaskEntryItem> items;

  const SessionTaskQueue({required this.items});

  bool get isEmpty => items.isEmpty;

  /// The in-progress task — the one the agent works on. Null when none:
  /// either the queue is empty or every task is finished. At most one
  /// when the writers validated; a corrupt hand-sewn log with two shows
  /// the first rather than picking silently.
  TaskEntryItem? get current {
    for (final item in items) {
      if (item.state == 'in_progress') return item;
    }
    return null;
  }

  /// The not-yet-started tasks, in queue order.
  List<TaskEntryItem> get pending =>
      items.where((i) => i.state == 'pending').toList();

  List<TaskEntryItem> get done => items.where((i) => i.state == 'done').toList();

  List<TaskEntryItem> get skipped =>
      items.where((i) => i.state == 'skipped').toList();

  /// The task that starts when the current one completes — the first
  /// pending item in order. Null when nothing is queued.
  TaskEntryItem? get next {
    for (final item in items) {
      if (item.state == 'pending') return item;
    }
    return null;
  }

  @override
  bool operator ==(Object other) =>
      other is SessionTaskQueue && _listEquals(items, other.items);

  @override
  int get hashCode => Object.hashAll(items);

  @override
  String toString() =>
      'SessionTaskQueue(${items.length} items, ${pending.length} pending)';
}

extension TasksProjection on DerivedSession {
  SessionTaskQueue? get taskQueue {
    final raw = pluginStates['tina/tasks']?['queue'];
    if (raw == null || raw.value == null) return null;
    final e = TaskQueueEntry.decode(raw);
    return SessionTaskQueue(items: e.items);
  }
}
