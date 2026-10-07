import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:tina_context/tina_context.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

Message text(String value) =>
    Message(role: Role.user, content: [TextBlock(value)]);
List<String> texts(Iterable<Message> messages) => [
      for (final m in messages)
        for (final b in m.content.whereType<TextBlock>()) b.text,
    ];
List<SessionEntry> history() => [
      const TurnStartedEntry(turnId: 'old', seq: 0),
      MessageAppendedEntry(turnId: 'old', message: text('old history'), seq: 1),
      const TurnEndedEntry(
          turnId: 'old', reason: TurnStopReason.complete, seq: 2),
    ];

void edit(File file, void Function(Map<String, dynamic>) change) {
  final data = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
  change(data);
  file.writeAsStringSync(jsonEncode(data));
}

void main() {
  late Directory dir;
  late File file;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('tina-context-mirror-');
    file = File('${dir.path}/session/live.json');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('mounting is opt-in and overwrites leftover edits from restored state',
      () {
    final plugin = ContextPlugin(mirrorFile: file);
    file.parent.createSync(recursive: true);
    file.writeAsStringSync('uncommitted leftover');
    final loop = AgentLoop(
        provider: ScriptedProvider([]), plugins: [plugin], seedLog: history());
    loop.mountPlugin(plugin);
    final data = jsonDecode(file.readAsStringSync()) as Map;
    expect(data['revision'], 0);
    expect(data['through_seq'], 2);
    expect(
        (data['messages'] as List).single['content'][0]['text'], 'old history');
    expect(dir.listSync(recursive: true).whereType<File>(), hasLength(1));
  });

  test('unchanged mirror refreshes appended history without a snapshot',
      () async {
    final plugin = ContextPlugin(mirrorFile: file);
    final provider = ScriptedProvider([scriptedReply('done')]);
    final loop =
        AgentLoop(provider: provider, plugins: [plugin], seedLog: history());
    loop.mountPlugin(plugin);
    await loop.runTurn(const Input('task', id: 'new'));
    expect(plugin.lastReceipt!.status, ContextEditStatus.unchanged);
    expect(loop.log.whereType<PluginStateEntry>(), isEmpty);
    expect(texts(provider.requests.single.messages), ['old history', 'task']);
    expect(provider.requests.single.systemPrompt, contains(file.path));
    expect(provider.requests.single.systemPrompt, contains('32000 tokens'));
    expect(plugin.budgetTokens, 32000);
  });

  test('configured context budget is reflected in the next request', () async {
    var budget = 16000;
    final plugin =
        ContextPlugin(mirrorFile: file, readBudgetTokens: () => budget);
    final provider = ScriptedProvider([
      scriptedReply('done'),
      scriptedReply('again'),
    ]);
    final loop = AgentLoop(provider: provider, plugins: [plugin]);
    loop.mountPlugin(plugin);
    await loop.runTurn(const Input('task', id: 'one'));
    expect(provider.requests.last.systemPrompt, contains('16000 tokens'));
    budget = 48000;
    await loop.runTurn(const Input('next', id: 'two'));
    expect(provider.requests.last.systemPrompt, contains('48000 tokens'));
    budget = 0;
    expect(() => plugin.budgetTokens, throwsFormatException);
  });

  test('file tools can evict settled exchanges within the active turn',
      () async {
    final plugin = ContextPlugin(mirrorFile: file);
    final provider = ScriptedProvider([
      scriptedReply('',
          calls: const [ToolUseBlock(id: 'one', name: 'edit', input: {})]),
      scriptedReply('',
          calls: const [ToolUseBlock(id: 'two', name: 'edit', input: {})]),
      scriptedReply('done'),
    ]);
    final loop =
        AgentLoop(provider: provider, plugins: [plugin], seedLog: history());
    loop.mountPlugin(plugin);
    var executions = 0;
    loop.registerExecutor('edit', (_) async {
      executions++;
      edit(file, (data) {
        data['messages'] = [
          for (final m in data['messages'] as List)
            if (m['content'][0]['type'] == 'text' &&
                m['content'][0]['text'] == 'task')
              m,
        ];
      });
      return ToolResult('result $executions');
    });
    final outcome = await loop.runTurn(const Input('task', id: 'new'));
    expect(outcome.stopReason, StopReason.complete);
    expect(executions, 2);
    expect(plugin.lastReceipt!.status, ContextEditStatus.accepted);
    expect(plugin.workingContext.revision, 2);
    final retained = provider.requests.last.messages
        .expand((m) => m.content)
        .whereType<ToolResultBlock>();
    expect(retained.map((r) => r.toolUseId), ['two']);
    expect(texts(provider.requests.last.messages),
        ['task', 'Context edit accepted.']);
    expect(
        loop.log
            .whereType<MessageAppendedEntry>()
            .expand((e) => e.message.content)
            .whereType<ToolResultBlock>(),
        hasLength(2));
    expect(texts(deriveWorkingContext(loop.log).messages), ['task', 'done']);
  });

  test('malformed file is rejected, restored, and yields a short receipt',
      () async {
    final plugin = ContextPlugin(mirrorFile: file);
    final provider = ScriptedProvider([scriptedReply('done')]);
    final loop =
        AgentLoop(provider: provider, plugins: [plugin], seedLog: history());
    loop.mountPlugin(plugin);
    file.writeAsStringSync('{not json');
    await loop.runTurn(const Input('task', id: 'new'));
    expect(plugin.lastReceipt!.status, ContextEditStatus.rejected);
    expect(plugin.workingContext.revision, 0);
    expect(jsonDecode(file.readAsStringSync())['messages'], hasLength(2));
    expect(texts(provider.requests.single.messages).take(2),
        ['old history', 'task']);
    expect(texts(provider.requests.single.messages).last, contains('rejected'));
  });

  test('changed metadata, bad shapes and missing files never replace state',
      () {
    final current =
        WorkingContext(revision: 1, throughSeq: 4, messages: [text('saved')]);
    final mirror = ContextFileMirror(file);
    for (final mutate in <void Function()>[
      () => edit(file, (data) => data['revision'] = 99),
      () => edit(file, (data) => data['through_seq'] = 99),
      () => edit(file, (data) => data['schema_version'] = 99),
      () => file.writeAsStringSync('[]'),
      () => edit(file, (data) => data['messages'] = 'bad'),
      () => file.deleteSync(),
    ]) {
      mirror.initialize(current);
      mutate();
      mirror.synchronize(current, (_) => throw StateError('must not replace'));
      expect(mirror.lastReceipt!.status, ContextEditStatus.rejected);
      expect(jsonDecode(file.readAsStringSync())['revision'], 1);
    }
  });

  test('a concurrent replacement or reset makes changed mirror stale', () {
    final base =
        WorkingContext(revision: 1, throughSeq: 4, messages: [text('saved')]);
    final mirror = ContextFileMirror(file);
    for (final current in [
      WorkingContext(
          revision: 2, throughSeq: 5, messages: [text('other edit')]),
      WorkingContext(revision: 1, throughSeq: 5, messages: []),
    ]) {
      mirror.initialize(base);
      edit(file, (data) => data['messages'] = [text('edited').toJson()]);
      mirror.synchronize(current, (_) => throw StateError('must not replace'));
      expect(mirror.lastReceipt!.status, ContextEditStatus.rejected);
      expect(jsonDecode(file.readAsStringSync())['messages'],
          [for (final m in current.messages) m.toJson()]);
    }
  });

  test('removing current task is rejected even after tool batch settles',
      () async {
    final plugin = ContextPlugin(mirrorFile: file);
    final provider = ScriptedProvider([
      scriptedReply('',
          calls: const [ToolUseBlock(id: 'one', name: 'edit', input: {})]),
      scriptedReply('done'),
    ]);
    final loop = AgentLoop(provider: provider, plugins: [plugin]);
    loop.mountPlugin(plugin);
    loop.registerExecutor('edit', (_) async {
      edit(file, (data) => data['messages'] = []);
      return const ToolResult('output');
    });
    await loop.runTurn(const Input('task', id: 'new'));
    expect(plugin.lastReceipt!.status, ContextEditStatus.rejected);
    expect(plugin.workingContext.revision, 0);
    expect(texts(provider.requests.last.messages).first, 'task');
  });

  test('replacement during an executing batch cannot erase pending calls',
      () async {
    final plugin = ContextPlugin();
    final provider = ScriptedProvider([
      scriptedReply('',
          calls: const [ToolUseBlock(id: 'one', name: 'tool', input: {})]),
      scriptedReply('done'),
    ]);
    final loop = AgentLoop(provider: provider, plugins: [plugin]);
    loop.mountPlugin(plugin);
    loop.registerExecutor('tool', (_) async {
      final current = plugin.workingContext;
      expect(
          () => plugin.replaceWorkingContext(
              expectedRevision: current.revision,
              expectedThroughSeq: current.throughSeq,
              messages: [text('task')]),
          throwsA(isA<ContextEditRejected>()));
      return const ToolResult('output');
    });
    await loop.runTurn(const Input('task', id: 'new'));
    expect(plugin.workingContext.revision, 0);
  });

  test('a mirror edit with failed persistence never reaches the next request',
      () async {
    final plugin = ContextPlugin(mirrorFile: file);
    final provider = ScriptedProvider([
      scriptedReply('',
          calls: const [ToolUseBlock(id: 'one', name: 'edit', input: {})]),
      scriptedReply('must not run'),
    ]);
    final loop =
        AgentLoop(provider: provider, plugins: [plugin], seedLog: history());
    loop.mountPlugin(plugin);
    loop.subscribe((entry, event) {
      if (event == LogEvent.appended && entry is PluginStateEntry) {
        throw const FormatException('store failure');
      }
    });
    loop.registerExecutor('edit', (_) async {
      edit(file, (data) => (data['messages'] as List).removeAt(0));
      return const ToolResult('output');
    });
    final result = await loop.runTurn(const Input('task', id: 'new'));
    expect(result.stopReason, StopReason.error);
    expect(provider.callCount, 1);
    expect(() => plugin.workingContext, throwsStateError);
  });

  test('file publish failure blocks the provider and cleans temporary files',
      () async {
    final plugin = ContextPlugin(mirrorFile: file);
    final provider = ScriptedProvider([scriptedReply('must not run')]);
    final loop = AgentLoop(provider: provider, plugins: [plugin]);
    loop.mountPlugin(plugin);
    file.deleteSync();
    Directory(file.path).createSync();
    final result = await loop.runTurn(const Input('task', id: 'new'));
    expect(result.stopReason, StopReason.error);
    expect(provider.callCount, 0);
    expect(file.parent.listSync().whereType<File>(), isEmpty);
  });
}
