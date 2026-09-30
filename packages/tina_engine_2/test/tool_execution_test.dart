import 'dart:async';
import 'package:test/test.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

final class ExampleTool extends AgentPlugin {
  @override
  String get id => 'test/tool';
  @override
  List<ToolSchema> get tools =>
      const [ToolSchema(name: 'example', description: '', inputSchema: {})];
}

final class DescribedTool extends AgentPlugin {
  DescribedTool(this.id, this.title);
  @override
  final String id;
  final String title;
  @override
  List<ToolSchema> get tools => [
        ToolSchema(
            name: 'example',
            description: '',
            inputSchema: const {},
            describe: (_) => ToolDescription(title: title)),
      ];
}

void main() {
  test('tool descriptions follow current registrations and tool precedence',
      () {
    final loop = AgentLoop(provider: ScriptedProvider([]), plugins: [
      DescribedTool('test/a', 'First description'),
      DescribedTool('test/b', 'Second description'),
    ]);
    String? title() => loop.toolSchema('example')?.describe?.call({}).title;
    expect(title(), 'Second description');
    loop.removePlugin('test/b');
    expect(title(), 'First description');
    loop.removePlugin('test/a');
    expect(loop.toolSchema('example'), isNull);
    loop.addPlugin(DescribedTool('test/c', 'Loaded description'));
    expect(title(), 'Loaded description');
    expect(loop.toolSchema('unknown'), isNull);
  });

  test(
      'execution observes cancellation, pairs the result and ignores late output',
      () async {
    final loop = AgentLoop(
        provider: ScriptedProvider([
          scriptedReply('',
              calls: [ToolUseBlock(id: 'call', name: 'example', input: {})]),
          scriptedReply('next turn'),
        ]),
        plugins: [ExampleTool()]);
    final started = Completer<void>();
    late ToolExecutionContext retained;
    loop.registerContextExecutor('example', (input, context) async {
      retained = context;
      context.report('working');
      context.progress('reading child output');
      started.complete();
      await context.whenCancelled;
      expect(context.isCancelled(), true);
      context.report('late output');
      context.progress('late progress');
      return const ToolResult('cancelled after cleanup', isError: true);
    });
    final events = <ToolActivity>[];
    final subscription = loop.toolActivity.listen(events.add);
    addTearDown(subscription.cancel);
    final turn = loop.runTurn(const Input('run', id: 'first'));
    await started.future;
    expect(events.map((event) => event.runtimeType),
        [ToolStarted, ToolOutput, ToolProgress]);
    loop.cancel('escape');
    expect((await turn).stopReason, StopReason.cancelled);
    retained.report('after result');
    retained.progress('after result');
    expect(events.map((event) => event.runtimeType),
        [ToolStarted, ToolOutput, ToolProgress, ToolFinished]);
    final results = loop.log
        .whereType<MessageAppendedEntry>()
        .expand((entry) => entry.message.content)
        .whereType<ToolResultBlock>();
    expect(results.single.toolUseId, 'call');
    expect(results.single.content, 'cancelled after cleanup');
    expect((await loop.runTurn(const Input('again', id: 'second'))).stopReason,
        StopReason.complete);
  });
}
