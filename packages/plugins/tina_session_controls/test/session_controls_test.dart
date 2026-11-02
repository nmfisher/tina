import 'dart:async';

import 'package:test/test.dart';
import 'package:tina_session_controls/tina_session_controls.dart';
import 'package:tina_engine_2/tina_engine_2.dart';
import 'package:tina_host/tina_host.dart';

final class _Terminal implements Terminal {
  final lines = <String>[];
  @override
  void writeln([String? line]) => lines.add(line ?? '');
  @override
  Future<String> ask(String prompt) async => '';
}

void main() {
  test(
    'model operations share recent selections and reject stale picker responses',
    () async {
      var model = 'one';
      var switches = 0;
      final models = ['one', 'two'];
      final plugin = SessionControlsPlugin(
        terminal: _Terminal(),
        currentModel: () => model,
        switchModel: (value) {
          model = value;
          switches++;
        },
        modelCatalog: () => ModelCatalog(models: models),
      );
      final first = plugin.observation, second = plugin.observation;
      final catalog = first.catalog;
      expect(() => catalog.models.clear(), throwsUnsupportedError);
      models.add('three');
      expect(catalog.models, ['one', 'two']);
      expect(second.catalog.models, ['one', 'two', 'three']);
      plugin.selectModel('two', expectedModel: first.currentModel);
      expect(second.currentModel, 'two');
      expect(second.recentModels, ['two']);
      expect(() => second.recentModels.clear(), throwsUnsupportedError);
      expect(
        () => plugin.selectModel('one', expectedModel: 'one'),
        throwsStateError,
      );
      models.remove('three');
      expect(
        () => plugin.selectModel('three', expectedModel: 'two'),
        throwsArgumentError,
      );
      expect(model, 'two');
      plugin.closeSession();
      expect(
        () => plugin.selectModel('one', expectedModel: 'two'),
        throwsStateError,
      );
      await plugin.commands.first.handler('three');
      expect(switches, 1);
    },
  );

  test('clear remains a runtime command after presentation detaches', () async {
    final plugin = SessionControlsPlugin(
      terminal: _Terminal(),
      currentModel: () => 'one',
      switchModel: (_) {},
      modelCatalog: () => const ModelCatalog(),
    );
    final loop = AgentLoop(
      provider: ScriptedProvider([scriptedReply('answer')]),
      plugins: [plugin],
    );
    plugin.mountOn(loop);
    await loop.runTurn(const Input('go', id: 'turn'));
    await plugin.commands.last.handler('');
    expect(loop.log.last, isA<ContextClearedEntry>());
    plugin.closeSession();
  });

  test('reasoning shows the current choice and rejects unknown words', () async {
    final terminal = _Terminal();
    var effort = 'medium';
    final plugin = SessionControlsPlugin(
      terminal: terminal,
      currentModel: () => 'openai/gpt-test',
      switchModel: (_) {},
      modelCatalog: () => const ModelCatalog(),
      currentReasoning: () => effort,
      setReasoning: (value) => effort = value,
      reasoningChoices: () => const ['auto', 'none', 'low', 'medium', 'high'],
    );
    final reasoning = plugin.commands[1];
    await reasoning.handler('');
    expect(terminal.lines.last, 'Reasoning: medium');
    await reasoning.handler('high');
    expect(effort, 'high');
    expect(terminal.lines.last, 'Reasoning: high (applies to the next request)');
    terminal.lines.clear();
    await reasoning.handler('bogus');
    expect(effort, 'high');
    expect(terminal.lines.last,
        'no reasoning level named bogus — choices: auto, none, low, medium, high');
    // Completion offers the model's vocabulary, not the canonical superset.
    expect(reasoning.complete!('h'), ['high']);
  });

  test('reasoning auto reports automatic and is case-insensitive', () async {
    final terminal = _Terminal();
    String? effort;
    final plugin = SessionControlsPlugin(
      terminal: terminal,
      currentModel: () => 'openai/gpt-test',
      switchModel: (_) {},
      modelCatalog: () => const ModelCatalog(),
      currentReasoning: () => effort ?? 'auto',
      setReasoning: (value) => effort = value == 'auto' ? null : value,
    );
    final reasoning = plugin.commands[1];
    await reasoning.handler('');
    expect(terminal.lines.last, 'Reasoning: automatic (provider default)');
    await reasoning.handler('HIGH');
    expect(effort, 'high');
    await reasoning.handler('Auto');
    expect(effort, isNull);
    expect(terminal.lines.last,
        'Reasoning: automatic (applies to the next request)');
  });

  test('reasoning reports unavailable without host wiring', () async {
    final terminal = _Terminal();
    final plugin = SessionControlsPlugin(
      terminal: terminal,
      currentModel: () => 'openai/gpt-test',
      switchModel: (_) {},
      modelCatalog: () => const ModelCatalog(),
    );
    await plugin.commands[1].handler('high');
    expect(terminal.lines.last, 'Reasoning control is unavailable in this session.');
  });

  test('a refused switch surfaces its reason, not a bare type name', () {
    final plugin = SessionControlsPlugin(
      terminal: _Terminal(),
      currentModel: () => 'one',
      switchModel: (_) =>
          throw StateError('model switching requires an idle turn'),
      modelCatalog: () => const ModelCatalog(models: ['one', 'two']),
    );
    final result = sessionControlsOperations['select-model']!.control!(
        plugin, {'model': 'two', 'expected_model': 'one'});
    expect(result.stopReason, StopReason.error);
    expect(result.detail, 'Bad state: model switching requires an idle turn');
  });

  test(
      'the picker switches models while between-turns work is running '
      'and the next request uses the new model', () async {
    Host? hostRef;
    var current = 'one';
    final controls = SessionControlsPlugin(
      terminal: _Terminal(),
      currentModel: () => current,
      switchModel: (value) {
        hostRef!.switchModel(value);
        current = value;
      },
      modelCatalog: () => const ModelCatalog(models: ['one', 'two']),
    );
    final inside = Completer<void>(), held = Completer<void>();
    final one = ScriptedProvider([scriptedReply('one')]);
    final two = ScriptedProvider([scriptedReply('two')]);
    final host = hostRef = Host.start(HostConfig(
      workingDirectory: '.',
      providerFactory: (model) => model == 'two' ? two : one,
      plugins: [controls, _HoldPlugin(inside, held)],
      operationsFor: (_) => sessionControlsOperations,
    ));
    addTearDown(host.shutdown);
    final client = host.connect();
    addTearDown(client.close);
    // Between-turns work in flight, shaped like a running /compact.
    final work = host.commands['hold']!.handler('');
    await inside.future;
    final request = client.submitOperation('tina/session-controls',
        'select-model',
        arguments: {'model': 'two', 'expected_model': 'one'},
        id: client.requestWindow.id('pick'));
    expect(request.snapshot.state, SessionRequestState.completed,
        reason: 'a read of the picker during compaction must not be idle-gated');
    expect(host.model, 'two');
    expect(host.session.loop.provider, same(one),
        reason: 'the running work keeps its provider until it ends');
    held.complete();
    await work;
    expect(host.session.loop.provider, same(two));
    await host.send('go');
    expect(two.callCount, 1);
    expect(one.callCount, 0);
  });

  test('the picker during a running turn fails with the refusal reason',
      () async {
    Host? hostRef;
    var current = 'one';
    final release = Completer<void>();
    final provider = _WaitingProvider(release.future);
    final controls = SessionControlsPlugin(
      terminal: _Terminal(),
      currentModel: () => current,
      switchModel: (value) {
        hostRef!.switchModel(value);
        current = value;
      },
      modelCatalog: () => const ModelCatalog(models: ['one', 'two']),
    );
    final host = hostRef = Host.start(HostConfig(
      workingDirectory: '.',
      providerFactory: (_) => provider,
      plugins: [controls],
      operationsFor: (_) => sessionControlsOperations,
    ));
    addTearDown(host.shutdown);
    final client = host.connect();
    addTearDown(client.close);
    final turn = host.send('go');
    await provider.arrived.future;
    expect(host.session.loop.inTurn, isTrue);
    final request = client.submitOperation('tina/session-controls',
        'select-model',
        arguments: {'model': 'two', 'expected_model': 'one'},
        id: client.requestWindow.id('pick'));
    final result = await request.completed;
    expect(result.state, SessionRequestState.failed);
    expect(result.result!.detail, 'Bad state: model switching requires an idle turn');
    expect(current, 'one', reason: 'the turn keeps its model');
    release.complete();
    expect((await turn).stopReason, StopReason.complete);
  });
}

/// A plugin whose command holds between-turns loop work open, shaped like
/// the compaction plugin's /compact.
final class _HoldPlugin extends AgentPlugin {
  _HoldPlugin(this.inside, this.held);

  final Completer<void> inside, held;
  AgentLoop? _loop;

  @override
  String get id => 'test/hold';

  @override
  void mountOn(AgentLoop loop) => _loop = loop;

  @override
  List<Command> get commands => [
        Command(
            name: 'hold',
            description: 'hold between-turns work open',
            handler: (_) => _loop!.betweenTurns(() async {
                  inside.complete();
                  await held.future;
                }))
      ];
}

/// A provider that never answers until released, so a test can act while
/// the loop owns an in-flight turn request.
final class _WaitingProvider implements LlmProvider {
  _WaitingProvider(this.release);

  final Future<void> release;
  final arrived = Completer<void>();

  @override
  String get model => 'waiting';

  @override
  Stream<StreamEvent> send(
      {required String system,
      required List<Message> messages,
      required List<ToolSchema> tools}) async* {
    arrived.complete();
    await release;
    yield const MessageComplete(
        content: [TextBlock('done')], stopReason: 'end_turn');
  }

  @override
  void close() {}
}
