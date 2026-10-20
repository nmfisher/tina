// The tasks plugin: the queued follow-up tasks the agent works through
// one at a time. The tests pin the three surfaces and the truth: every
// change lands as a TaskQueueEntry on the log (the entry IS the queue —
// the latest wins, a resume replays it), the model-facing section renders
// the current task and the boundary from the plan, the /task command
// edits through the terminal, and completing the current task starts the
// first pending one and offers a continuation through the loop's steering
// input.
//
// Run: dart test
library;

import 'dart:async';
import 'dart:io';

import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';
import 'package:tina_persistence/tina_persistence.dart';
import 'package:tina_tasks/tina_tasks.dart';
import 'package:test/test.dart';

/// A capturing terminal — the same shape the plans command's tests use.
final class _CaptureTerminal implements Terminal {
  final lines = <String>[];
  final asks = <String>[];

  @override
  void writeln([String? line]) => lines.add(line ?? '');

  @override
  Future<String> ask(String prompt) async {
    asks.add(prompt);
    return '';
  }
}

/// A provider that holds a turn open until [gate] completes, so a test can
/// observe and drive the session mid-turn. The first request is gated and
/// carries a [query_tasks] call; later requests reply with plain text so the
/// turn can finish.
final class _GatedProvider implements LlmProvider {
  _GatedProvider(this.gate);
  final Completer<void> gate;
  final requests = <Request>[];
  var _calls = 0;

  @override
  String get model => 'gated';

  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) async* {
    requests.add(Request(
        systemPrompt: system, messages: messages, tools: tools));
    if (_calls++ == 0) {
      yield const ToolCallStart(id: 'c1', name: 'query_tasks');
      await gate.future;
      yield const MessageComplete(
        content: [ToolUseBlock(id: 'c1', name: 'query_tasks', input: {})],
        stopReason: 'tool_use',
      );
    } else {
      yield const TextDelta('ok');
      yield const MessageComplete(
          content: [TextBlock('ok')], stopReason: 'end_turn');
    }
  }

  @override
  void close() {}
}

/// A loop over a scripted provider with the tasks plugin mounted — the
/// minimal wiring every test starts from.
(AgentLoop, TasksPlugin, ScriptedProvider) _wired({Terminal? terminal}) {
  final provider = ScriptedProvider([]);
  final plugin = TasksPlugin(terminal: terminal);
  final loop = AgentLoop(provider: provider, plugins: [plugin]);
  plugin.mountOn(loop);
  return (loop, plugin, provider);
}

ToolUseBlock _call(String name, Map<String, Object?> input,
        {String id = 'call1'}) =>
    ToolUseBlock(id: id, name: name, input: input);

List<String> _sections(AgentLoop loop, TasksPlugin plugin) {
  // Rebuild the prompt-phase view: the sections the plugins add for the
  // current state.
  final ctx = TurnContext(
    CancelToken(),
    input: const Input('probe', id: 'probe'),
    pinnedTools: const [],
    messages: const [],
    promptSections: [],
  );
  plugin.onPrompt(ctx);
  return ctx.promptSections;
}

void main() {
  test('queue_task writes a TaskQueueEntry; the store replays the log',
      () async {
    final (loop, plugin, provider) = _wired();
    addTearDown(plugin.closeSession);
    await loop.runTurn(const Input('go', id: 't0'));
    provider.requests.clear();

    final result = await plugin.queueForTest({'text': 'write tests'});
    expect(result.isError, isFalse, reason: result.content);
    expect(result.content, contains('t1'));

    final entries = loop.log
        .whereType<PluginStateEntry>()
        .where(TaskQueueEntry.matches)
        .map(TaskQueueEntry.decode)
        .toList();
    expect(entries, hasLength(1));
    expect(entries.single.items.single.text, 'write tests');
    expect(entries.single.items.single.state, 'pending');
    expect(plugin.store.state.items, hasLength(1));
  });

  test('ids allocate uniquely and survive a resume replay', () async {
    final (loop, plugin, _) = _wired();
    addTearDown(plugin.closeSession);
    await plugin.queueForTest({'text': 'first'});
    await plugin.queueForTest({'text': 'second'});
    await plugin.queueForTest({'text': 'third'});
    expect(plugin.store.state.items.map((i) => i.id), ['t1', 't2', 't3']);

    // A fresh plugin over the same log resumes the id counter.
    final resumed = TasksPlugin();
    final loop2 = AgentLoop(
        provider: ScriptedProvider([]), plugins: [resumed], seedLog: loop.log);
    resumed.mountOn(loop2);
    addTearDown(resumed.closeSession);
    final result = await resumed.queueForTest({'text': 'fourth'});
    expect(result.isError, isFalse, reason: result.content);
    expect(resumed.store.state.items.last.id, 't4');
  });

  test('mark_task completes the current task and starts the next',
      () async {
    final (loop, plugin, _) = _wired();
    addTearDown(plugin.closeSession);
    await plugin.queueForTest({'text': 'first task'});
    await plugin.queueForTest({'text': 'second task'});

    final started = await plugin.markForTest({
      'id': 't1',
      'state': 'in_progress',
    });
    expect(started.isError, isFalse, reason: started.content);
    expect(plugin.store.state.current!.id, 't1');

    final done = await plugin.markForTest({'state': 'done'});
    expect(done.isError, isFalse, reason: done.content);
    expect(done.content, contains('t2'));
    expect(plugin.store.state.items[0].state, 'done');
    expect(plugin.store.state.current!.id, 't2');
    expect(plugin.store.state.pending, hasLength(0));
  });

  test('completing the last task empties the current slot and reports it',
      () async {
    final (loop, plugin, _) = _wired();
    addTearDown(plugin.closeSession);
    await plugin.queueForTest({'text': 'only task'});
    await plugin.markForTest({'id': 't1', 'state': 'in_progress'});
    await plugin.markForTest({'state': 'done'});
    expect(plugin.store.state.current, isNull);
    expect(plugin.store.state.pending, isEmpty);
    expect(plugin.store.state.items.single.state, 'done');
  });

  test('mark_task errors: unknown id, junk state, second in_progress, '
      'no current', () async {
    final (loop, plugin, _) = _wired();
    addTearDown(plugin.closeSession);
    await plugin.queueForTest({'text': 'a'});
    await plugin.queueForTest({'text': 'b'});
    final before = loop.log.length;

    expect((await plugin.markForTest({'state': 'sideways'})).isError, isTrue);
    expect((await plugin.markForTest({'id': 't9', 'state': 'done'})).isError,
        isTrue);
    expect(
        (await plugin.markForTest({'state': 'done'})).content,
        contains('no current task'));
    await plugin.markForTest({'id': 't1', 'state': 'in_progress'});
    final second =
        await plugin.markForTest({'id': 't2', 'state': 'in_progress'});
    expect(second.isError, isTrue);
    expect(second.content, contains('already in progress'));

    // Errors leave the queue untouched; the one successful mark appended.
    final entries = loop.log
        .whereType<PluginStateEntry>()
        .where(TaskQueueEntry.matches)
        .length;
    expect(entries, 3);
    expect(loop.log.length, before + 1);
  });

  test('queue_task position next inserts after the current task',
      () async {
    final (loop, plugin, _) = _wired();
    addTearDown(plugin.closeSession);
    await plugin.queueForTest({'text': 'a'});
    await plugin.queueForTest({'text': 'b'});
    await plugin.markForTest({'id': 't1', 'state': 'in_progress'}); // t1 runs
    await plugin.queueForTest({'text': 'urgent', 'position': 'next'});
    await plugin.queueForTest({'text': 'later'});

    expect(plugin.store.state.items.map((i) => i.text).toList(),
        ['a', 'urgent', 'b', 'later']);
    // "next" means the next task after the current one.
    expect(plugin.store.state.next!.text, 'urgent');
  });

  test('query_tasks lists current, pending, done and skipped', () async {
    final (loop, plugin, _) = _wired();
    addTearDown(plugin.closeSession);
    expect((await plugin.queryForTest({})).content, contains('empty'));

    await plugin.queueForTest({'text': 'alpha'});
    await plugin.queueForTest({'text': 'beta'});
    await plugin.queueForTest({'text': 'gamma'});
    await plugin.markForTest({'id': 't1', 'state': 'in_progress'});
    await plugin.markForTest({'id': 't3', 'state': 'skipped'});

    final result = await plugin.queryForTest({});
    expect(result.isError, isFalse);
    expect(result.content, contains('current: [~] t1 alpha'));
    expect(result.content, contains('pending:'));
    expect(result.content, contains('t2 beta'));
    expect(result.content, contains('done: none'));
    expect(result.content, contains('skipped: [-] t3 gamma'));
  });

  test('the schema validation holds the line: bad queue_task calls are '
      'tool errors, the log is untouched', () async {
    final (loop, plugin, _) = _wired();
    addTearDown(plugin.closeSession);
    await loop.runTurn(const Input('go', id: 't0'));
    final before = loop.log.length;

    expect((await plugin.queueForTest({'text': ''})).isError, isTrue);
    expect((await plugin.queueForTest({})).isError, isTrue);
    expect(
        (await plugin.queueForTest({'text': 'x' * (taskMaxTextLength + 1)}))
            .isError,
        isTrue);
    expect((await plugin.queueForTest({'text': 'ok', 'position': 'top'}))
        .isError, isTrue);
    expect((await plugin.queueForTest({'text': 'ok', 'summary': 42}))
        .isError, isTrue);

    // Saturate the queue: the cap is a tool error, not a crash.
    for (var i = 0; i < taskMaxItems; i++) {
      expect((await plugin.queueForTest({'text': 'task $i'})).isError,
          isFalse,
          reason: 'item $i');
    }
    expect((await plugin.queueForTest({'text': 'overflow'})).isError, isTrue);
    expect(loop.log.length - before, taskMaxItems);
  });

  test('the prompt section names the current task and the plan boundary',
      () async {
    final (loop, plugin, _) = _wired();
    addTearDown(plugin.closeSession);
    expect(_sections(loop, plugin), isEmpty);

    await plugin.queueForTest({'text': 'current work'});
    await plugin.queueForTest({'text': 'later work'});
    await plugin.markForTest({'id': 't1', 'state': 'in_progress'});
    final sections = _sections(loop, plugin);
    expect(sections, hasLength(1));
    final section = sections.single;
    expect(section, startsWith('<task-queue>'));
    expect(section, endsWith('</task-queue>'));
    expect(section, contains('Current task: [~] t1 current work'));
    expect(section, contains('Queued next: [ ] t2 later work'));
    expect(section, contains('not the plan'));
    expect(section, contains('mark_task'));
  });

  test('the section on a finished queue tells the agent the work is done',
      () async {
    final (loop, plugin, _) = _wired();
    addTearDown(plugin.closeSession);
    await plugin.queueForTest({'text': 'only'});
    await plugin.markForTest({'id': 't1', 'state': 'in_progress'});
    await plugin.markForTest({'state': 'done'});
    final section = _sections(loop, plugin).single;
    expect(section, contains('No current task'));
    expect(section, contains('All tasks are complete'));
  });

  test('the entry round trips the store bytes: toJson then fromJson is '
      'the same queue', () {
    const entry = TaskQueueEntry(items: [
      TaskEntryItem(
          id: 't1',
          text: 'in progress task',
          summary: 'What this one does.',
          state: 'in_progress'),
      TaskEntryItem(id: 't2', text: 'queued task', state: 'pending'),
    ]);
    final back = TaskQueueEntry.decode(
        SessionEntry.fromJson(entry.toJson()..remove('seq'))
            as PluginStateEntry);
    expect(back, isA<TaskQueueEntry>());
    expect(back, entry);
    expect(back.items.first.summary, 'What this one does.');
    expect(back.items.last.id, 't2');

    // Junk is refused, not silently repaired.
    expect(
        () => TaskQueueEntry.fromJson({
              'items': [
                {'id': 't1', 'text': 'x', 'state': 'sideways'},
                {'id': 't2', 'text': 'y', 'state': 'pending'},
              ],
            }, '', 0),
        throwsA(isA<FormatException>()));
    expect(
        () => TaskQueueEntry.fromJson({
              'items': [
                {'id': 't1', 'text': 'x', 'state': 'pending'},
                {'id': 't1', 'text': 'y', 'state': 'pending'},
              ],
            }, '', 0),
        throwsA(isA<FormatException>()));
    expect(
        () => TaskQueueEntry.fromJson({
              'items': [
                for (var i = 0; i <= TaskQueueEntry.maxItems; i++)
                  {'id': 't$i', 'text': 'x', 'state': 'pending'},
              ],
            }, '', 0),
        throwsA(isA<FormatException>()));
  });

  test('old entries without summaries remain readable; missing state '
      'decodes as pending', () {
    final entry = TaskQueueEntry.fromJson({
      'items': [
        {'id': 't1', 'text': 'old task'},
      ],
    }, '', 0);
    expect(entry.items.single.summary, '');
    expect(entry.items.single.state, 'pending');
    expect(entry.value['items'].single.containsKey('summary'), false);
  });

  test('completing the current task mid-turn offers a continuation turn',
      () async {
    final provider = ScriptedProvider([
      scriptedReply('working', calls: [
        _call('mark_task', {'state': 'done'}, id: 'c1'),
      ]),
      scriptedReply('on to the next'),
    ]);
    final plugin = TasksPlugin();
    final loop = AgentLoop(provider: provider, plugins: [plugin]);
    plugin.mountOn(loop);
    addTearDown(plugin.closeSession);

    await plugin.queueForTest({'text': 'first task'});
    await plugin.queueForTest({'text': 'second task'});
    await plugin.markForTest({'id': 't1', 'state': 'in_progress'});

    final outcome = await loop.runTurn(const Input('go', id: 't1'));
    // The first turn ends, then the offered continuation runs as a
    // successor turn inside the same runTurn call.
    expect(outcome.stopReason, StopReason.complete);
    expect(plugin.store.state.current!.id, 't2');
    expect(provider.callCount, 2);
    // The successor request carries the continuation prompt.
    final lastUser = provider.requests.last.messages.last.content
        .whereType<TextBlock>()
        .map((b) => b.text)
        .join();
    expect(lastUser, contains('[task queue]'));
    expect(lastUser, contains('second task'));
  });

  test('the offer is refused when no turn runs; nothing auto-runs later',
      () async {
    final (loop, plugin, _) = _wired();
    addTearDown(plugin.closeSession);
    await plugin.queueForTest({'text': 'first'});
    await plugin.queueForTest({'text': 'second'});
    await plugin.markForTest({'id': 't1', 'state': 'in_progress'});
    await plugin.markForTest({'state': 'done'});
    // Between turns the queue advanced but no continuation turn exists.
    expect(loop.pendingInputCount, 0);
    expect(plugin.store.state.current!.id, 't2');
    // The section drives the next turn instead.
    expect(_sections(loop, plugin).single, contains('Current task'));
  });

  test('the /task command edits the queue through the terminal', () async {
    final terminal = _CaptureTerminal();
    final (loop, plugin, _) = _wired(terminal: terminal);
    addTearDown(plugin.closeSession);
    final handler = plugin.commands.single.handler;
    expect(plugin.commands.single.name, 'task');
    expect(plugin.commands.single.allowWhileRunning, isTrue);

    await handler('');
    expect(terminal.lines.last, contains('No tasks'));

    await handler('write the docs');
    expect(plugin.store.state.items.single.text, 'write the docs');
    expect(terminal.lines.last, contains('t1 write the docs'));

    await handler('next fix the bug first');
    expect(plugin.store.state.items.first.text, 'fix the bug first');
    expect(plugin.store.state.items.last.text, 'write the docs');

    // Start the current task, then finish it via /task done. After the
    // "next" insert the items are [t2 fix, t1 write]; finishing t1 (the
    // current task) promotes t2 to in_progress.
    await plugin.markForTest({'id': 't1', 'state': 'in_progress'});
    await handler('done');
    expect(plugin.store.state.items[0].state, 'in_progress');
    expect(plugin.store.state.items[1].state, 'done');
    expect(terminal.lines.any((l) => l.contains('t1 done')), isTrue);

    await handler('remove 2');
    expect(plugin.store.state.items, hasLength(1));
    expect(terminal.lines.last, contains('Removed t1'));

    await handler('skip 1');
    expect(plugin.store.state.items.single.state, 'skipped');

    await handler('one more');
    await handler('clear');
    expect(plugin.store.state.isEmpty, isTrue);
    expect(terminal.lines.last, contains('cleared'));
  });

  test('clearing the conversation context also clears the task queue',
      () async {
    final (loop, plugin, _) = _wired(terminal: _CaptureTerminal());
    addTearDown(plugin.closeSession);
    await plugin.commands.single.handler('write the docs');
    expect(plugin.store.state.items, hasLength(1));

    loop.clearHistory();

    expect(plugin.store.state.isEmpty, isTrue);
  });

  test('the /task command works while a turn runs (allowWhileRunning)',
      () async {
    final gate = Completer<void>();
    final provider = _GatedProvider(gate);
    final terminal = _CaptureTerminal();
    final plugin = TasksPlugin(terminal: terminal);
    final loop = AgentLoop(provider: provider, plugins: [plugin]);
    plugin.mountOn(loop);
    addTearDown(plugin.closeSession);

    final turn = loop.runTurn(const Input('go', id: 't1'));
    await pumpEventQueue();
    expect(loop.running, isTrue);

    await plugin.commands.single.handler('a follow-up');
    expect(plugin.store.state.items.single.text, 'a follow-up');
    expect(terminal.lines.last, contains('t1 a follow-up'));

    gate.complete();
    await turn;
    expect(plugin.store.state.items.single.text, 'a follow-up');
  });

  test('the queue survives a store round trip: a resumed host derives it',
      () async {
    final ws = await Directory.systemTemp.createTemp('tina_tasks_ws_');
    addTearDown(() => ws.deleteSync(recursive: true));
    final storePath = '${ws.path}/session.db';

    final startedPlugin = TasksPlugin();
    final started = Host.start(HostConfig(
      providerFactory: (_) => ScriptedProvider([]),
      workingDirectory: ws.path,
      plugins: [
        startedPlugin,
        PersistencePlugin(openStore: () => SessionStore.open(storePath)),
      ],
    ));
    await started.session.loop.runTurn(const Input('queue it', id: 't1'));
    await startedPlugin.queueForTest({'text': 'surviving task'});
    await startedPlugin.markForTest({'id': 't1', 'state': 'in_progress'});
    final sessionId = started.session.id;
    started.close();

    final resumed = Host.resume(
      HostConfig(
        providerFactory: (_) => ScriptedProvider([]),
        workingDirectory: ws.path,
        plugins: [
          TasksPlugin(),
          PersistencePlugin(openStore: () => SessionStore.open(storePath)),
        ],
      ),
      sessionId,
    );
    final resumedPlugin = resumed.plugins.whereType<TasksPlugin>().single;
    final view = resumed.session.loop.derive();
    expect(view.taskQueue, isNotNull);
    expect(view.taskQueue!.items.single.text, 'surviving task');
    expect(view.taskQueue!.items.single.state, 'in_progress');
    expect(resumedPlugin.store.state.current!.text, 'surviving task');
    // The resumed plugin allocates fresh ids after its replay.
    final result = await resumedPlugin.queueForTest({'text': 'another'});
    expect(result.isError, isFalse, reason: result.content);
    expect(resumedPlugin.store.state.items.last.id, 't2');
    resumed.close();
  });

  test('future plugin state is opaque while disabled and rejected by its '
      'owner', () async {
    final state = PluginStateEntry.snapshot(
        pluginId: 'tina/tasks',
        stateKey: 'queue',
        schemaVersion: 999,
        value: {'future': true});
    final loop = AgentLoop(
        provider: ScriptedProvider([scriptedReply('ok')]),
        plugins: [],
        seedLog: [state]);
    expect((await loop.runTurn(const Input('hello', id: 'one'))).stopReason,
        StopReason.complete);
    final plugin = TasksPlugin();
    final enabled = AgentLoop(
        provider: ScriptedProvider([]), plugins: [plugin], seedLog: [state]);
    expect(() => plugin.mountOn(enabled), throwsFormatException);
    plugin.closeSession();
    expect(loop.log.first.toJson(), state.toJson());
  });

  test('observation snapshots are immutable and update on changes',
      () async {
    final (loop, plugin, _) = _wired();
    addTearDown(plugin.closeSession);
    await plugin.queueForTest({'text': 'one'});
    final snapshot = plugin.observation.state;
    expect(() => snapshot.items.clear(), throwsUnsupportedError);
    await plugin.queueForTest({'text': 'two'});
    expect(snapshot.items, hasLength(1));
    expect(plugin.observation.state.items, hasLength(2));
  });
}

extension _TestExecutors on TasksPlugin {
  /// The tool executors, exposed for direct calls — the tests exercise
  /// the same functions the loop dispatches.
  Future<ToolResult> markForTest(Map<String, Object?> input) =>
      executeMark(input);

  Future<ToolResult> queueForTest(Map<String, Object?> input) =>
      executeQueue(input);

  Future<ToolResult> queryForTest(Map<String, Object?> input) =>
      executeQuery(input);
}
