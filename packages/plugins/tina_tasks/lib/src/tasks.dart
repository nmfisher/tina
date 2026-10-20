/// The session's task queue: the ordered list of follow-up tasks the
/// agent works through one at a time, surfaced to the model as a prompt
/// section and to the user as the `/task` command.
///
/// Not the plan: the plan (`tina_plans`) is the step-by-step breakdown of
/// the *current* task and is replaced whenever the work changes; the
/// queue is *what comes after* and grows across tasks. The prompt section
/// spells that boundary out so the model never mirrors plan steps into
/// the queue.
///
/// The truth lives on the engine's one log, like every plugin state:
/// each change appends a [TaskQueueEntry] through the loop's state
/// writer, the entry **is** the queue (the latest one wins), and a resume
/// derives it the same way the running session saw it — so the current
/// task survives restart and compaction by construction.
///
/// The surfaces, split the brief's way:
/// - **model-written** — `mark_task`, `queue_task` (executors on the loop);
/// - **model-read** — the `<task-queue>` section in `onPrompt` and the
///   `query_tasks` tool;
/// - **user-typed** — the `/task` command, told through the [Terminal].
///
/// Auto-advance: completing the current task starts the first pending
/// task in the same entry, then offers a continuation turn through
/// `AgentLoop.offerInput` — the loop's existing steering path — so the
/// agent moves on by itself without the engine growing a new mechanism.
/// When no turn is running (the completion came from `/task` between
/// turns) the offer is refused and the prompt section drives the next
/// turn instead; nothing auto-runs later.
library;

import '../observation.dart';

import 'dart:async';

import 'package:tina_engine_2/tina_engine_2.dart';

/// The caps and the state vocabulary, shared by the tool schemas and the
/// store's validation — one vocabulary, both directions.
const taskMaxItems = TaskQueueEntry.maxItems;
const taskMaxTextLength = TaskEntryItem.maxTextLength;
const taskMaxSummaryLength = TaskEntryItem.maxSummaryLength;

const _states = TaskEntryItem.stateWords;

/// One queue for one session, held by the plugin. The log carries the
/// durable truth; this cell is the plugin's view of the latest entry,
/// updated by its own log listener. Not conversation-scoped: one host is
/// one session in this engine.
class TaskStore {
  TaskState _state = TaskState(items: const []);

  late final TaskObservation observation = _TaskObservation(this);

  /// The queue now. Empty when the session carries none.
  TaskState get state => _state;

  /// Serves surfaces that want to repaint on a queue change without
  /// subscribing to raw entries.
  final _changes = StreamController<void>.broadcast();

  Stream<void> get changes => _changes.stream;

  /// Replace the queue wholesale. Validates exactly what the entry can
  /// carry: the caps, unique non-empty ids, non-empty trimmed text, the
  /// state vocabulary, at most one in-progress task. Throws
  /// [ArgumentError] on violations so a malformed model call surfaces as
  /// a tool error, not a broken log.
  void replace(AgentLoop loop, List<TaskEntryItem> items) {
    _validate(items);
    _write(loop, items);
  }

  static void _validate(List<TaskEntryItem> items) {
    if (items.length > taskMaxItems) {
      throw ArgumentError('task queue exceeds $taskMaxItems items');
    }
    final ids = <String>{};
    var inProgress = 0;
    for (final item in items) {
      if (item.id.isEmpty) {
        throw ArgumentError('task items must have non-empty ids');
      }
      if (!ids.add(item.id)) {
        throw ArgumentError('duplicate task id: ${item.id}');
      }
      final text = item.text.trim();
      if (text.isEmpty) {
        throw ArgumentError('task items must have non-empty text');
      }
      if (text.length > taskMaxTextLength) {
        throw ArgumentError('task text exceeds $taskMaxTextLength chars');
      }
      if (item.summary.length > taskMaxSummaryLength) {
        throw ArgumentError(
            'task summary exceeds $taskMaxSummaryLength chars');
      }
      if (!_states.contains(item.state)) {
        throw ArgumentError(
            'task state must be one of ${_states.join(", ")}');
      }
      if (item.state == 'in_progress') inProgress++;
    }
    if (inProgress > 1) {
      throw ArgumentError('at most one task may be in progress');
    }
  }

  void _write(AgentLoop loop, List<TaskEntryItem> items) {
    _writer!(TaskQueueEntry(items: List.of(items)));
    _state = TaskState(items: List.of(items));
    _changes.add(null);
  }

  void Function(PluginStateEntry)? _writer;

  /// Adopt a replayed entry — the plugin's log listener calls this; it is
  /// not a user-facing mutation path and performs no validation beyond
  /// what the entry's decode already enforced.
  void adopt(TaskState state) {
    _state = state;
    _changes.add(null);
  }

  /// Replay from the loop's log — the startup and resume path. The
  /// listener wired in [TasksPlugin.mountOn] does this once; surfaces
  /// reading [state] before that see an empty queue.
  void hydrateFrom(List<SessionEntry> log) {
    TaskQueueEntry? latest;
    for (final e in log) {
      if (TaskQueueEntry.matches(e)) {
        latest = TaskQueueEntry.decode(e as PluginStateEntry);
      }
    }
    _state = latest == null
        ? TaskState(items: const [])
        : TaskState(items: List.of(latest.items));
  }

  void dispose() {
    _changes.close();
  }
}

final class _TaskObservation implements TaskObservation {
  _TaskObservation(this._store);
  final TaskStore _store;

  TaskState get state => _store.state;
  @override
  String? get unavailableReason => null;
  @override
  void Function() listen(void Function() changed) {
    final subscription = _store.changes.listen((_) => changed());
    return () => unawaited(subscription.cancel());
  }
}

String _box(String state) => switch (state) {
      'in_progress' => '[~]',
      'done' => '[x]',
      'skipped' => '[-]',
      _ => '[ ]',
    };

/// Renders the model-facing section: the queue boundary, the current
/// task, the rule that drives auto-advance. Returns '' for an empty
/// queue — a section that says "there are no tasks" is noise, and the
/// join drops empties.
String taskSection(TaskState queue) {
  if (queue.isEmpty) return '';
  final buffer = StringBuffer(
    '<task-queue>\n'
    'This conversation has a task queue. It is not the plan: the plan is '
    'the step-by-step breakdown of the current task; the queue is the list '
    'of tasks that come after it.\n',
  );
  final current = queue.current;
  if (current != null) {
    buffer.writeln('Current task: ${_box(current.state)} ${current.id} '
        '${current.text}');
    buffer.writeln('Work ONLY on the current task. Call mark_task(state: '
        '"done") the moment it is complete — the first queued task then '
        'starts automatically and you continue with it.');
  } else {
    buffer.writeln('No current task. Start the first pending task with '
        'mark_task(id: <id>, state: "in_progress").');
  }
  final pending = queue.pending;
  final next = queue.next;
  if (next != null && next.id != current?.id) {
    buffer.writeln('Queued next: ${_box(next.state)} ${next.id} '
        '${next.text}');
  }
  if (pending.isEmpty && current == null) {
    buffer.writeln('All tasks are complete; the queue needs no further '
        'work unless the user adds tasks.');
  }
  buffer.writeln('When the user asks for follow-up work, add it with '
      'queue_task instead of doing it inside the current task. Use '
      'query_tasks when the queue state is unclear.');
  for (final item in queue.items) {
    if (item == current) continue;
    buffer.writeln('${_box(item.state)} ${item.id} ${item.text}');
    if (item.summary.trim().isNotEmpty) {
      for (final line in item.summary.split('\n')) {
        buffer.writeln('  $line');
      }
    }
  }
  buffer.write('</task-queue>');
  return buffer.toString();
}

/// The plugin: owns the three tools, the section and the command; mounts
/// the executors; keeps [store] current by listening to the log.
class TasksPlugin extends AgentPlugin {
  TasksPlugin({
    this.id = 'tina/tasks',
    this.order = 22,
    this.terminal,
  });

  @override
  final String id;

  /// After plans (20), before goals (25).
  @override
  final int order;

  final Terminal? terminal;

  final TaskStore store = TaskStore();

  TaskObservation get observation => store.observation;

  AgentLoop? _loop;
  int? _subscription;
  bool _closed = false;

  /// The next queue id to hand out (`t1`, `t2`, …). Recomputed from the
  /// queue after every adopted entry so a resume keeps allocating fresh
  /// ids.
  int _nextId = 1;

  void _syncNextId() {
    var highest = 0;
    for (final item in store.state.items) {
      final match = RegExp(r'^t(\d+)$').firstMatch(item.id);
      if (match == null) continue;
      final value = int.tryParse(match.group(1)!);
      if (value != null && value > highest) highest = value;
    }
    _nextId = highest + 1;
  }

  String _allocateId() => 't${_nextId++}';

  @override
  void closeSession() {
    if (_closed) return;
    _closed = true;
    if (_subscription != null) _loop?.unsubscribe(_subscription!);
    _loop = null;
    store.dispose();
  }

  @override
  List<ToolSchema> get tools => [_markSchema, _queueSchema, _querySchema];

  ToolSchema get _markSchema => ToolSchema(
        describe: (input) => ToolDescription(
            title: 'Mark task',
            target: input['id'] is String
                ? '${input['id']} → ${input['state']}'
                : '${input['state']}'),
        name: 'mark_task',
        description:
            'Mark a task\'s progress in the session\'s task queue. The '
            'default target is the current task (the in_progress one); '
            'pass id to target another task. state "done" completes it — '
            'when that is the current task, the first queued task starts '
            'automatically and you continue with it in the next turn. '
            'Use state "skipped" for a task that must not run. At most '
            'one task may be in_progress at a time.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'id': {
              'type': 'string',
              'description':
                  'The task id (from query_tasks or the task-queue '
                      'section). Omit to target the current task.',
            },
            'state': {
              'type': 'string',
              'enum': _states,
              'description':
                  'The new state. "done" on the current task starts the '
                      'next queued task automatically.',
            },
          },
          'required': ['state'],
        },
      );

  ToolSchema get _queueSchema => ToolSchema(
        describe: (input) => ToolDescription(
            title: 'Queue task',
            target: input['text'] is String ? input['text'] as String : ''),
        name: 'queue_task',
        description:
            'Add a follow-up task to the session\'s task queue. Use it '
            'when the user asks for work that should happen after the '
            'current task, or when a discrete follow-up emerges. The '
            'queue is not the plan: do not mirror plan steps here. '
            'position "next" inserts the task before the other pending '
            'tasks; "end" (default) appends it.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'text': {
              'type': 'string',
              'maxLength': taskMaxTextLength,
              'description': 'Short task title.',
            },
            'summary': {
              'type': 'string',
              'maxLength': taskMaxSummaryLength,
              'description':
                  'What this task will do and its intended outcome.',
            },
            'position': {
              'type': 'string',
              'enum': ['next', 'end'],
              'description':
                  '"next" runs before the other pending tasks; "end" '
                      'appends (default).',
            },
          },
          'required': ['text'],
        },
      );

  ToolSchema get _querySchema => ToolSchema(
        describe: (_) => const ToolDescription(title: 'Query tasks'),
        name: 'query_tasks',
        description:
            'Inspect the session\'s task queue: the current task, what '
            'is still pending (not yet started), what is done and what '
            'was skipped. Takes no arguments.',
        inputSchema: {
          'type': 'object',
          'properties': {},
        },
      );

  @override
  void onPrompt(TurnContext c) {
    final section = taskSection(store.state);
    if (section.isNotEmpty) c.promptSections.add(section);
  }

  /// Mount the executors and replay the log into [store]. Idempotent
  /// against double-mount: a second mount re-wires nothing.
  @override
  void mountOn(AgentLoop loop) {
    if (_loop != null) return;
    _loop = loop;
    store._writer = loop.stateWriter(id);
    store.hydrateFrom(loop.log);
    _syncNextId();
    loop.registerExecutor('mark_task', executeMark);
    loop.registerExecutor('queue_task', executeQueue);
    loop.registerExecutor('query_tasks', executeQuery);
    _subscription = loop.subscribe((entry, event) {
      if (TaskQueueEntry.matches(entry)) {
        final decoded = TaskQueueEntry.decode(entry as PluginStateEntry);
        store.adopt(TaskState(items: List.of(decoded.items)));
        _syncNextId();
      }
    });
  }

  /// State word from raw model input, or null when junk.
  static String? _decodeState(Object? raw) => switch (raw) {
        'pending' || 'in_progress' || 'done' || 'skipped' => raw as String,
        _ => null,
      };

  /// `mark_task`: transition one task, advance the queue when the current
  /// one completes, and offer a continuation turn. Validation errors
  /// surface as tool errors — the model reads the reason and corrects the
  /// call; nothing here throws past the executor boundary.
  Future<ToolResult> executeMark(Map<String, Object?> input) async {
    final loop = _loop;
    if (loop == null) return ToolResult.error('mark_task is not mounted');
    final state = _decodeState(input['state']);
    if (state == null) {
      return ToolResult.error(
          'mark_task state must be one of ${_states.join(", ")}');
    }
    final id = switch (input['id']) {
      String value when value.isNotEmpty => value,
      _ => null,
    };
    final items = List.of(store.state.items);
    if (items.isEmpty) return ToolResult.error('the task queue is empty');
    final current = store.state.current;
    final TaskEntryItem target;
    if (id != null) {
      final found = items.where((i) => i.id == id).firstOrNull;
      if (found == null) return ToolResult.error('no task "$id" in the queue');
      target = found;
    } else {
      if (current == null) {
        return ToolResult.error(
            'no current task: pass id, or start a pending task with '
            'state "in_progress"');
      }
      target = current;
    }
    if (state == 'in_progress' &&
        current != null &&
        current.id != target.id) {
      return ToolResult.error(
          'task ${current.id} is already in progress; complete or skip it '
          'first');
    }
    final wasCurrent = current?.id == target.id;
    final advance = wasCurrent &&
        (state == 'done' || state == 'skipped') &&
        store.state.next != null;
    final updated = <TaskEntryItem>[];
    TaskEntryItem? started;
    for (final item in items) {
      if (item.id == target.id) {
        updated.add(item.copyWith(state: state));
      } else if (advance &&
          item.state == 'pending' &&
          started == null &&
          item.id == store.state.next!.id) {
        started = item.copyWith(state: 'in_progress');
        updated.add(started);
      } else {
        updated.add(item);
      }
    }
    try {
      store.replace(loop, updated);
    } on ArgumentError catch (error) {
      return ToolResult.error(error.message?.toString() ?? 'invalid queue');
    }
    final doneWord = state == 'skipped' ? 'skipped' : 'done';
    if (started != null) {
      final offered = _offerContinuation(loop, target, started);
      return ToolResult(
          'Task ${target.id} $doneWord. ${started.id} '
          '"${started.text}" is now in progress${offered ? '' : ' — '
              'continue with it'}.');
    }
    if (wasCurrent) {
      return ToolResult('Task ${target.id} $doneWord. '
          '${store.state.pending.isEmpty ? 'The queue is empty.' : 'No '
              'task is in progress; start the next one with mark_task.'}');
    }
    return ToolResult('Task ${target.id} marked $doneWord.');
  }

  /// The auto-advance path: offer the continuation through the loop's
  /// steering input. False when the loop is not mid-turn (the completion
  /// came from `/task` between turns) — the prompt section drives the
  /// next turn instead; nothing is lost.
  bool _offerContinuation(
      AgentLoop loop, TaskEntryItem finished, TaskEntryItem started) {
    if (_closed || !loop.running) return false;
    return loop.offerInput(Input(
      '[task queue] "${finished.text}" (${finished.id}) is complete. '
      'Begin the next task: "${started.text}" (${started.id}). Work it to '
      'completion, then call mark_task(state: "done").',
      id: 'task-advance-${started.id}',
    ));
  }

  /// `queue_task`: append or insert one pending task.
  Future<ToolResult> executeQueue(Map<String, Object?> input) async {
    final loop = _loop;
    if (loop == null) return ToolResult.error('queue_task is not mounted');
    final rawText = input['text'];
    if (rawText is! String || rawText.trim().isEmpty) {
      return ToolResult.error('queue_task requires non-empty text');
    }
    final text = rawText.trim();
    if (text.length > taskMaxTextLength) {
      return ToolResult.error(
          'queue_task text exceeds $taskMaxTextLength chars');
    }
    final rawSummary = input['summary'];
    if (rawSummary != null && rawSummary is! String) {
      return ToolResult.error('queue_task summary must be a string');
    }
    final summary = rawSummary as String? ?? '';
    if (summary.length > taskMaxSummaryLength) {
      return ToolResult.error(
          'queue_task summary exceeds $taskMaxSummaryLength chars');
    }
    final insertNext = switch (input['position']) {
      null || 'end' => false,
      'next' => true,
      _ => null,
    };
    if (insertNext == null) {
      return ToolResult.error('queue_task position must be "next" or "end"');
    }
    final items = List.of(store.state.items);
    if (items.length >= taskMaxItems) {
      return ToolResult.error(
          'task queue exceeds $taskMaxItems items; complete or clear '
          'tasks first');
    }
    final item = TaskEntryItem(
        id: _allocateId(), text: text, summary: summary, state: 'pending');
    if (insertNext) {
      var anchor = 0;
      for (var i = 0; i < items.length; i++) {
        final current = items[i].state == 'in_progress';
        if (current) anchor = i + 1;
      }
      items.insert(anchor, item);
    } else {
      items.add(item);
    }
    try {
      store.replace(loop, items);
    } on ArgumentError catch (error) {
      return ToolResult.error(error.message?.toString() ?? 'invalid queue');
    }
    return ToolResult(
        'Queued ${item.id} "${item.text}"${insertNext ? ' (next)' : ''}.');
  }

  /// `query_tasks`: the read-only queue listing — current, pending
  /// (not yet started), done, skipped.
  Future<ToolResult> executeQuery(Map<String, Object?> input) async {
    final queue = store.state;
    if (queue.isEmpty) return const ToolResult('The task queue is empty.');
    final current = queue.current;
    final buffer = StringBuffer();
    if (current != null) {
      buffer.writeln('current: ${_box(current.state)} ${current.id} '
          '${current.text}');
    } else {
      buffer.writeln('current: none');
    }
    String group(String label, Iterable<TaskEntryItem> items) {
      final list = items.toList();
      if (list.isEmpty) return '$label: none\n';
      return '$label: ${[for (final i in list) '${_box(i.state)} ${i.id} ${i.text}'].join('; ')}\n';
    }

    buffer.write(group('pending', queue.pending));
    buffer.write(group('done', queue.items.where((i) => i.state == 'done')));
    buffer.write(
        group('skipped', queue.items.where((i) => i.state == 'skipped')));
    return ToolResult(buffer.toString().trimRight());
  }

  /// The user's surface: `/task` — show, add, insert, remove, clear,
  /// done/skip. `allowWhileRunning` so the user can queue follow-ups
  /// while the agent works; log writes are legal mid-turn.
  @override
  List<Command> get commands => terminal == null
      ? const []
      : [
          Command(
            name: 'task',
            complete: (prefix) => [
              'next',
              'remove',
              'clear',
              'done',
              'skip',
            ].where((word) => word.startsWith(prefix)).toList(),
            description:
                'show or edit the task queue (add text to queue a '
                'follow-up task)',
            handler: _taskCommand,
            allowWhileRunning: true,
          )
        ];

  Future<void> _taskCommand(String argument) async {
    final loop = _loop;
    final terminal = this.terminal!;
    final args = argument.trim();
    if (args.isEmpty) {
      _showQueue(terminal);
      return;
    }
    if (RegExp(r'^clear$', caseSensitive: false).hasMatch(args)) {
      if (loop == null) return;
      store.replace(loop, const []);
      terminal.writeln('Task queue cleared.');
      return;
    }
    final insertNext =
        RegExp(r'^next\s+(.+)$', caseSensitive: false).firstMatch(args);
    if (insertNext != null) {
      if (loop == null) return;
      await _queueFromCommand(terminal, insertNext.group(1)!, insertNext: true);
      return;
    }
    final remove =
        RegExp(r'^remove\s+(\d+)$', caseSensitive: false).firstMatch(args);
    if (remove != null) {
      if (loop == null) return;
      final index = int.parse(remove.group(1)!) - 1;
      final items = store.state.items;
      if (index < 0 || index >= items.length) {
        terminal.writeln('No task ${index + 1}.');
        return;
      }
      final removed = items[index];
      final updated = [...items]..removeAt(index);
      store.replace(loop, updated);
      terminal.writeln('Removed ${removed.id} "${removed.text}".');
      return;
    }
    final settle = RegExp(r'^(done|skip)(?:\s+(\d+))?$',
            caseSensitive: false)
        .firstMatch(args);
    if (settle != null) {
      if (loop == null) return;
      final state = settle.group(1)!.toLowerCase() == 'done'
          ? 'done'
          : 'skipped';
      final rawIndex = settle.group(2);
      String? id;
      if (rawIndex != null) {
        id = _idForIndex(int.parse(rawIndex), terminal);
        if (id == null) return; // reported by _idForIndex
      }
      final result = await executeMark({'state': state, if (id != null) 'id': id});
      terminal.writeln(result.content);
      _showQueue(terminal);
      return;
    }
    // Free text appends one pending task.
    await _queueFromCommand(terminal, args);
  }

  String? _idForIndex(int oneBased, Terminal terminal) {
    final items = store.state.items;
    final index = oneBased - 1;
    if (index < 0 || index >= items.length) {
      terminal.writeln('No task $oneBased.');
      return null;
    }
    return items[index].id;
  }

  Future<void> _queueFromCommand(Terminal terminal, String text,
      {bool insertNext = false}) async {
    final result = await executeQueue({
      'text': text,
      if (insertNext) 'position': 'next',
    });
    terminal.writeln(result.content);
    if (!result.isError) _showQueue(terminal);
  }

  void _showQueue(Terminal terminal) {
    final queue = store.state;
    if (queue.isEmpty) {
      terminal.writeln(
          'No tasks. `/task <text>` queues one; the agent works them in '
          'order and starts the next automatically.');
      return;
    }
    final current = queue.current;
    final buffer = StringBuffer('Task queue:\n');
    for (final (i, item) in queue.items.indexed) {
      final marker = current?.id == item.id ? ' ← current' : '';
      buffer.writeln(
          '  ${i + 1}. ${_box(item.state)} ${item.id} ${item.text}$marker');
      if (item.summary.trim().isNotEmpty) {
        for (final line in item.summary.split('\n')) {
          buffer.writeln('      $line');
        }
      }
    }
    terminal.writeln(buffer.toString());
  }
}
