import 'package:attractor/attractor.dart';
import 'package:test/test.dart';

/// tin-80ll: nodes no longer carry a `role`; identity comes from a node-level
/// `system_prompt` and the model from `llm_model` + `llm_provider`. These tests
/// pin the new typed getters on [PipelineNode].
void main() {
  group('PipelineNode node identity (system_prompt / llm_model / llm_provider)',
      () {
    test('system_prompt is read from the system_prompt attr', () {
      final n = PipelineNode(id: 'main', attrs: {
        'system_prompt': 'You are a coding agent.',
      });
      expect(n.systemPrompt, 'You are a coding agent.');
    });

    test('instructions is accepted as an alias for system_prompt', () {
      final n = PipelineNode(id: 'main', attrs: {
        'instructions': 'You review code.',
      });
      expect(n.systemPrompt, 'You review code.');
    });

    test('system_prompt prefers system_prompt over instructions', () {
      final n = PipelineNode(id: 'main', attrs: {
        'system_prompt': 'primary',
        'instructions': 'secondary',
      });
      expect(n.systemPrompt, 'primary');
    });

    test('system_prompt is empty when neither attr is set', () {
      expect(PipelineNode(id: 'main').systemPrompt, '');
    });

    test('llm_model and llm_provider are read from their attrs', () {
      final n = PipelineNode(id: 'main', attrs: {
        'llm_model': 'claude-sonnet-4-6',
        'llm_provider': 'anthropic',
      });
      expect(n.llmModel, 'claude-sonnet-4-6');
      expect(n.llmProvider, 'anthropic');
    });

    test('modelReference combines provider and model as provider/model', () {
      final n = PipelineNode(id: 'main', attrs: {
        'llm_model': 'deepseek-chat',
        'llm_provider': 'deepseek',
      });
      expect(n.modelReference, 'deepseek/deepseek-chat');
    });

    test('modelReference is empty unless both provider and model are set', () {
      expect(
          PipelineNode(id: 'a', attrs: {'llm_model': 'm'}).modelReference, '');
      expect(
          PipelineNode(id: 'a', attrs: {'llm_provider': 'p'}).modelReference,
          '');
      expect(PipelineNode(id: 'a').modelReference, '');
    });

    test('the new attrs round-trip through parseDot/graphToDot', () {
      const src = '''
digraph L {
  start [shape=Mdiamond]
  done [shape=Msquare]
  main [shape=box, system_prompt="You are the main agent.", llm_model="sonnet", llm_provider="anthropic"]
  start -> main -> done
}
''';
      final g2 = parseDot(graphToDot(parseDot(src)));
      final main = g2.nodes['main']!;
      expect(main.systemPrompt, 'You are the main agent.');
      expect(main.llmModel, 'sonnet');
      expect(main.llmProvider, 'anthropic');
      expect(main.modelReference, 'anthropic/sonnet');
    });
  });
}
