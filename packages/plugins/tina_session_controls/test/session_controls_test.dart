import 'package:test/test.dart';
import 'package:tina_session_controls/tina_session_controls.dart';
import 'package:tina_engine_2/tina_engine_2.dart';

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
}
