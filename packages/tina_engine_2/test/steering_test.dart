import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

class Tools extends AgentPlugin {
  @override
  String get id => 'test/tools';
  @override
  List<ToolSchema> get tools =>
      const [ToolSchema(name: 'job', description: '', inputSchema: {})];
}

class Guard extends AgentPlugin {
  final inputs = <String>[];
  @override
  String get id => 'test/guard';
  @override
  void onInput(TurnContext c) {
    inputs.add(c.input.text);
    if (c.input.text == 'deny') c.cancel('denied input');
  }
}

class StalledProvider extends LlmProvider {
  StalledProvider() : super('stalled');
  final first = StreamController<StreamEvent>();
  final ready = Completer<void>();
  int calls = 0;
  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) {
    if (++calls == 1) {
      ready.complete();
      return first.stream;
    }
    return Stream.value(const MessageComplete(
        content: [TextBlock('steered')], stopReason: 'end_turn'));
  }
}

void main() {
  test(
      'input interrupts a stalled model stream and retains text without fabricating unfinished tool calls',
      () async {
    final provider = StalledProvider();
    addTearDown(provider.first.close);
    final loop = AgentLoop(provider: provider, plugins: [Tools()]);
    var executions = 0;
    loop.registerExecutor('job', (_) async {
      executions++;
      return const ToolResult('should not execute');
    });
    final run = loop.runTurn(const Input('first', id: 'first'));
    await provider.ready.future;
    provider.first.add(const TextDelta('partial answer'));
    provider.first.add(const ToolCallStart(id: 'unfinished', name: 'job'));
    await Future<void>.delayed(const Duration(milliseconds: 10));
    loop.offerInput(const Input('new input', id: 'second'));
    expect((await run.timeout(const Duration(seconds: 2))).detail, 'steered');
    expect(provider.calls, 2);
    expect(executions, 0);
    final blocks = loop.derive().messages.expand((m) => m.content).toList();
    expect(blocks.whereType<TextBlock>().map((b) => b.text),
        ['first', 'partial answer', 'new input', 'steered']);
    expect(blocks.whereType<ToolUseBlock>(), isEmpty);
    expect(blocks.whereType<ToolResultBlock>(), isEmpty);
  });

  test(
      'input yields a tool, pairs every call, skips stale calls and runs hooks',
      () async {
    final guard = Guard();
    final provider = ScriptedProvider([
      scriptedReply('', calls: [
        const ToolUseBlock(id: 'one', name: 'job', input: {}),
        const ToolUseBlock(id: 'two', name: 'job', input: {}),
      ]),
      scriptedReply('new answer'),
    ]);
    final loop = AgentLoop(provider: provider, plugins: [Tools(), guard]);
    final started = Completer<void>();
    var executions = 0;
    loop.registerContextExecutor('job', (_, context) async {
      executions++;
      started.complete();
      await context.whenInputPending;
      expect(context.isCancelled(), false);
      return const ToolResult('job is running');
    });
    final run = loop.runTurn(const Input('start', id: 'first'));
    await started.future;
    expect(loop.offerInput(const Input('do this instead', id: 'second')), true);
    expect((await run).detail, 'new answer');
    expect(executions, 1);
    expect(guard.inputs, ['start', 'do this instead']);
    final messages = loop.derive().messages;
    final results =
        messages.expand((m) => m.content).whereType<ToolResultBlock>().toList();
    expect(results.map((r) => r.toolUseId), ['one', 'two']);
    expect(results.last.content, contains('not executed'));
    expect((messages.last.content.single as TextBlock).text, 'new answer');
    final entries = loop.log;
    final newInput = entries
        .indexWhere((e) => e is InputRecordedEntry && e.turnId == 'second');
    final lastResult = entries.lastIndexWhere((e) =>
        e is MessageAppendedEntry &&
        e.message.content.any((b) => b is ToolResultBlock));
    expect(newInput, greaterThan(lastResult));
  });

  test('steered input cannot bypass an input guard', () async {
    final guard = Guard();
    final provider = ScriptedProvider([
      scriptedReply('', calls: [
        const ToolUseBlock(id: 'one', name: 'job', input: {}),
      ])
    ]);
    final loop = AgentLoop(provider: provider, plugins: [Tools(), guard]);
    final started = Completer<void>();
    loop.registerContextExecutor('job', (_, context) async {
      started.complete();
      await context.whenInputPending;
      return const ToolResult('running');
    });
    final run = loop.runTurn(const Input('start', id: 'first'));
    await started.future;
    loop.offerInput(const Input('deny', id: 'second'));
    expect((await run).stopReason, StopReason.cancelled);
    expect(guard.inputs, ['start', 'deny']);
    expect(loop.log.whereType<InputRecordedEntry>().length, 2);
    expect(
        loop
            .derive()
            .messages
            .expand((m) => m.content)
            .whereType<TextBlock>()
            .map((b) => b.text),
        isNot(contains('deny')));
  });
}
