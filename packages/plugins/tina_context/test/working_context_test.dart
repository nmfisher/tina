import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_context/tina_context.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_persistence/tina_persistence.dart';

Message text(String value, [Role role = Role.user]) =>
    Message(role: role, content: [TextBlock(value)]);
List<String> texts(Iterable<Message> messages) => [
      for (final m in messages)
        for (final b in m.content.whereType<TextBlock>()) b.text,
    ];

List<SessionEntry> stamp(List<SessionEntry> entries) => [
      for (var i = 0; i < entries.length; i++) entries[i].withSeq(i),
    ];

final class Editor extends AgentPlugin {
  Editor(this.edit);
  final void Function(TurnContext) edit;
  @override
  String get id => 'test/editor';
  @override
  int get order => 700;
  @override
  void beforeModelCall(TurnContext c) => edit(c);
}

List<SessionEntry> completedHistory() => stamp([
      const TurnStartedEntry(turnId: 'a'),
      MessageAppendedEntry(turnId: 'a', message: text('question')),
      MessageAppendedEntry(
          turnId: 'a', message: text('answer', Role.assistant)),
      const TurnEndedEntry(turnId: 'a', reason: TurnStopReason.complete),
    ]);

PluginStateEntry snapshot(int revision, int throughSeq,
        {String? turn, String value = 'notes'}) =>
    WorkingContextSnapshot(
      revision: revision,
      throughSeq: throughSeq,
      originTurnId: turn,
      messages: [text(value)],
    ).toEntry();

void main() {
  test('mid-turn edit protects active task and keeps later tool results once',
      () async {
    final plugin = ContextPlugin();
    var calls = 0;
    late AgentLoop loop;
    final editor = Editor((c) {
      if (++calls != 2) return;
      final current = plugin.workingContext;
      expect(
          () => plugin.replaceWorkingContext(
              expectedRevision: current.revision,
              expectedThroughSeq: current.throughSeq,
              messages: [text('lost task')]),
          throwsStateError);
      plugin.replaceWorkingContext(
          expectedRevision: current.revision,
          expectedThroughSeq: current.throughSeq,
          messages: [text('notes'), ...c.messages.skip(2)]);
    });
    final provider = ScriptedProvider([
      scriptedReply('',
          calls: const [ToolUseBlock(id: 'one', name: 'tool', input: {})]),
      scriptedReply('',
          calls: const [ToolUseBlock(id: 'two', name: 'tool', input: {})]),
      scriptedReply('done'),
    ]);
    loop = AgentLoop(
        provider: provider,
        plugins: [editor, plugin],
        seedLog: completedHistory());
    loop.mountPlugin(plugin);
    loop.registerExecutor('tool', (_) async => const ToolResult('output'));
    final result = await loop.runTurn(const Input('task', id: 'b'));
    expect(result.stopReason, StopReason.complete);
    expect(texts(provider.requests.last.messages), ['notes', 'task']);
    final results = provider.requests.last.messages
        .expand((m) => m.content)
        .whereType<ToolResultBlock>();
    expect(results.map((r) => r.toolUseId), ['one', 'two']);
    final restored = deriveWorkingContext(loop.log);
    expect(sameMessages(restored.messages, plugin.workingContext.messages),
        isTrue);
    expect(texts(restored.messages), ['notes', 'task', 'done']);
  });

  test('tail appends invalidate an editor cursor without another edit',
      () async {
    final plugin = ContextPlugin();
    final loop = AgentLoop(
        provider: ScriptedProvider([scriptedReply('done')]),
        plugins: [plugin],
        seedLog: completedHistory());
    loop.mountPlugin(plugin);
    final old = plugin.workingContext;
    await loop.runTurn(const Input('next', id: 'b'));
    expect(plugin.workingContext.revision, old.revision);
    expect(
        () => plugin.replaceWorkingContext(
            expectedRevision: old.revision,
            expectedThroughSeq: old.throughSeq,
            messages: [text('stale')]),
        throwsStateError);
  });

  test('signed reasoning cannot be rewritten or fabricated', () {
    final log = stamp([
      const TurnStartedEntry(turnId: 'a'),
      const MessageAppendedEntry(
          turnId: 'a',
          message: Message(
              role: Role.assistant,
              content: [TextBlock('answer')],
              reasoning: [ReasoningBlock('original', signature: 'sig')])),
      const TurnEndedEntry(turnId: 'a', reason: TurnStopReason.complete),
    ]);
    final plugin = ContextPlugin();
    final loop = AgentLoop(
        provider: ScriptedProvider([]), plugins: [plugin], seedLog: log);
    loop.mountPlugin(plugin);
    final current = plugin.workingContext;
    expect(
        () => plugin.replaceWorkingContext(
                expectedRevision: current.revision,
                expectedThroughSeq: current.throughSeq,
                messages: const [
                  Message(
                      role: Role.assistant,
                      content: [TextBlock('answer')],
                      reasoning: [ReasoningBlock('modified', signature: 'sig')])
                ]),
        throwsFormatException);
    expect(loop.log.length, log.length);
  });
  test('bootstrap matches core derivation including existing compaction', () {
    final log = stamp([
      ...completedHistory(),
      const CompactedEntry(replacedFrom: 0, replacedTo: 1, summary: 'summary'),
    ]);
    expect(
        sameMessages(deriveWorkingContext(log).messages,
            deriveSession(log, const SessionSettings()).messages),
        isTrue);
  });

  test('snapshot replaces history and tail is incorporated exactly once', () {
    final log = stamp([
      ...completedHistory(),
      snapshot(1, 3),
      const TurnStartedEntry(turnId: 'b'),
      MessageAppendedEntry(turnId: 'b', message: text('next')),
      const TurnEndedEntry(turnId: 'b', reason: TurnStopReason.complete),
    ]);
    final before = jsonEncode(log.map((e) => e.toJson()).toList());
    for (var i = 0; i < 2; i++) {
      expect(texts(deriveWorkingContext(log).messages), ['notes', 'next']);
    }
    expect(jsonEncode(log.map((e) => e.toJson()).toList()), before);
  });

  test('abandoned edit falls back; only the latest open turn can be live', () {
    final log = stamp([
      ...completedHistory(),
      snapshot(1, 3, value: 'saved'),
      const TurnStartedEntry(turnId: 'b'),
      MessageAppendedEntry(turnId: 'b', message: text('unfinished')),
      snapshot(2, 6, turn: 'b', value: 'provisional'),
    ]);
    expect(texts(deriveWorkingContext(log).messages), ['saved']);
    expect(texts(deriveWorkingContext(log, includePendingTurn: true).messages),
        ['provisional']);
    final resumed = stamp([
      ...log,
      const TurnStartedEntry(turnId: 'c'),
      MessageAppendedEntry(turnId: 'c', message: text('replayed')),
    ]);
    expect(
        texts(deriveWorkingContext(resumed, includePendingTurn: true).messages),
        ['saved', 'replayed']);
    expect(deriveWorkingContext(resumed).revision, 2);
  });

  test('all settled stop reasons preserve their snapshots', () {
    for (final reason in TurnStopReason.values) {
      final log = stamp([
        ...completedHistory(),
        const TurnStartedEntry(turnId: 'b'),
        MessageAppendedEntry(turnId: 'b', message: text('new')),
        snapshot(1, 5, turn: 'b'),
        TurnEndedEntry(turnId: 'b', reason: reason),
      ]);
      expect(texts(deriveWorkingContext(log).messages), ['notes']);
    }
  });

  test('clear prevents resurrection and preserves monotonic revisions', () {
    final log = stamp([
      ...completedHistory(),
      snapshot(1, 3),
      const ContextClearedEntry(),
    ]);
    expect(deriveWorkingContext(log).messages, isEmpty);
    expect(deriveWorkingContext(log).revision, 1);
  });

  test('compaction after an edit fails rather than splicing wrong positions',
      () {
    final log = stamp([
      ...completedHistory(),
      snapshot(1, 3),
      const CompactedEntry(replacedFrom: 0, replacedTo: 1, summary: 'bad'),
    ]);
    expect(() => deriveWorkingContext(log), throwsStateError);
  });

  test('corrupt versions, sequences and snapshot watermarks fail', () {
    expect(
        () => deriveWorkingContext([snapshot(1, 10)]), throwsFormatException);
    expect(
        () => deriveWorkingContext(
            [const TurnStartedEntry(turnId: 'bad', seq: 2)]),
        throwsFormatException);
    expect(
        () => deriveWorkingContext([
              PluginStateEntry.snapshot(
                  pluginId: contextPluginId,
                  stateKey: workingContextKey,
                  schemaVersion: 2,
                  value: {})
            ]),
        throwsFormatException);
  });

  test('messages round-trip images, signed reasoning and nested tool inputs',
      () {
    final input = <String, dynamic>{
      'nested': <String, dynamic>{'v': 1}
    };
    final messages = [
      Message(
          role: Role.assistant,
          content: [ToolUseBlock(id: 'call', name: 'tool', input: input)],
          reasoning: const [ReasoningBlock('thought', signature: 'sig')]),
      const Message(role: Role.user, content: [
        ToolResultBlock(
            toolUseId: 'call',
            content: 'result',
            images: [ImageBlock(data: 'aGVsbG8=', mimeType: 'image/png')])
      ]),
    ];
    final saved = WorkingContextSnapshot(
        revision: 1, throughSeq: -1, originTurnId: null, messages: messages);
    input['nested']['v'] = 2;
    final restored = WorkingContextSnapshot.fromEntry(
        SessionEntry.fromJson(saved.toEntry().toJson()) as PluginStateEntry);
    expect(sameMessages(saved.messages, restored.messages), isTrue);
    final call = restored.messages.first.content.single as ToolUseBlock;
    expect(call.input['nested']['v'], 1);
    expect(() => call.input['x'] = 3, throwsUnsupportedError);
    expect(() => call.input['nested']['v'] = 3, throwsUnsupportedError);
    expect(() => restored.messages.clear(), throwsUnsupportedError);
  });

  test('replacement rejects stale cursors and malformed tool exchanges', () {
    final plugin = ContextPlugin();
    final loop = AgentLoop(
        provider: ScriptedProvider([]),
        plugins: [plugin],
        seedLog: completedHistory());
    loop.mountPlugin(plugin);
    final current = plugin.workingContext;
    plugin.replaceWorkingContext(
        expectedRevision: current.revision,
        expectedThroughSeq: current.throughSeq,
        messages: [text('notes')]);
    expect(
        () => plugin.replaceWorkingContext(
            expectedRevision: current.revision,
            expectedThroughSeq: current.throughSeq,
            messages: [text('stale')]),
        throwsStateError);
    final next = plugin.workingContext;
    final count = loop.log.length;
    expect(
        () => plugin.replaceWorkingContext(
                expectedRevision: next.revision,
                expectedThroughSeq: next.throughSeq,
                messages: const [
                  Message(role: Role.user, content: [
                    ToolResultBlock(toolUseId: 'unknown', content: 'bad')
                  ])
                ]),
        throwsFormatException);
    expect(loop.log.length, count);
  });

  test('request hook uses edited context without changing core derive',
      () async {
    final provider = ScriptedProvider([scriptedReply('done')]);
    final plugin = ContextPlugin();
    final loop = AgentLoop(
        provider: provider, plugins: [plugin], seedLog: completedHistory());
    loop.mountPlugin(plugin);
    final current = plugin.workingContext;
    plugin.replaceWorkingContext(
        expectedRevision: current.revision,
        expectedThroughSeq: current.throughSeq,
        messages: [text('notes')]);
    await loop.runTurn(const Input('next', id: 'b'));
    expect(texts(provider.requests.single.messages), ['notes', 'next']);
    expect(
        texts(loop.derive().messages), ['question', 'answer', 'next', 'done']);
  });

  test('persistence failure poisons context and prevents provider requests',
      () async {
    final provider = ScriptedProvider([]);
    final plugin = ContextPlugin();
    final loop = AgentLoop(
        provider: provider, plugins: [plugin], seedLog: completedHistory());
    loop.mountPlugin(plugin);
    loop.subscribe((entry, event) {
      if (event == LogEvent.appended && entry is PluginStateEntry) {
        throw StateError('store failed');
      }
    });
    final current = plugin.workingContext;
    expect(
        () => plugin.replaceWorkingContext(
            expectedRevision: current.revision,
            expectedThroughSeq: current.throughSeq,
            messages: [text('notes')]),
        throwsStateError);
    final outcome = await loop.runTurn(const Input('next', id: 'b'));
    expect(outcome.stopReason, StopReason.error);
    expect(provider.callCount, 0);
  });

  test('SQLite close/reopen restores the same next model input', () async {
    final dir = Directory.systemTemp.createTempSync('tina-context-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/session.sqlite';
    PluginSession session(bool resuming) => PluginSession(
        id: 'session',
        workingDirectory: dir.path,
        resuming: resuming,
        notifyChanged: () {});
    final persistence =
        PersistencePlugin(openStore: () => SessionStore.open(path));
    persistence.openSession(session(false));
    final mirror = File('${dir.path}/live.json');
    final plugin = ContextPlugin(mirrorFile: mirror);
    final loop = AgentLoop(
        provider: ScriptedProvider([]),
        plugins: [persistence, plugin],
        seedLog: completedHistory());
    loop.mountPlugin(persistence);
    loop.mountPlugin(plugin);
    final current = plugin.workingContext;
    plugin.replaceWorkingContext(
        expectedRevision: current.revision,
        expectedThroughSeq: current.throughSeq,
        messages: [text('notes')]);
    final expected = plugin.workingContext;
    plugin.closeSession();
    persistence.closeSession();
    mirror.writeAsStringSync('uncommitted file edit');

    final reopened =
        PersistencePlugin(openStore: () => SessionStore.open(path));
    final seed = reopened.openSession(session(true))!;
    final restored = ContextPlugin(mirrorFile: mirror);
    final provider = ScriptedProvider([scriptedReply('done')]);
    final resumed = AgentLoop(
        provider: provider, plugins: [reopened, restored], seedLog: seed.log);
    resumed.mountPlugin(reopened);
    resumed.mountPlugin(restored);
    addTearDown(restored.closeSession);
    addTearDown(reopened.closeSession);
    expect(sameMessages(expected.messages, restored.workingContext.messages),
        isTrue);
    expect(restored.workingContext.revision, expected.revision);
    expect(jsonDecode(mirror.readAsStringSync())['messages'],
        [for (final m in expected.messages) m.toJson()]);
    await resumed.runTurn(const Input('next', id: 'b'));
    expect(texts(provider.requests.single.messages), ['notes', 'next']);
    expect(texts(resumed.derive().messages),
        ['question', 'answer', 'next', 'done']);
  });
}
