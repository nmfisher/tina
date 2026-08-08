import 'package:attractor/attractor.dart';
import 'package:test/test.dart';

void main() {
  group('graphToDot round-trip', () {
    test('round-trips a linear pipeline through parseDot', () {
      const src = '''
digraph Simple {
  graph [goal="Run tests"]
  start [shape=Mdiamond, label="Start"]
  exit [shape=Msquare, label="Exit"]
  run_tests [label="Run Tests", prompt="Run the suite"]
  start -> run_tests -> exit
}
''';
      final g = parseDot(src);
      final rewritten = graphToDot(g);
      final g2 = parseDot(rewritten);

      expect(g2.goal, 'Run tests');
      expect(g2.nodes.keys, containsAll(['start', 'exit', 'run_tests']));
      expect(g2.findStartNode()?.id, 'start');
      expect(g2.terminalNodes.single.id, 'exit');
      expect(g2.nodes['run_tests']!.prompt, 'Run the suite');
      expect(g2.edges.length, g.edges.length);
      expect(g2.outgoing('run_tests').single.to, 'exit');
    });

    test('preserves system_prompt/llm attrs, goal_gate, and edge condition/label/weight', () {
      const src = '''
digraph L {
  start [shape=Mdiamond]
  done [shape=Msquare]
  plan [shape=box, system_prompt="you plan", llm_model="sonnet", llm_provider="anthropic", goal_gate=true, max_retries=3]
  review [shape=box, system_prompt="you review"]
  start -> plan -> review
  review -> done [label="approve", condition="outcome=success"]
  review -> plan [label="revise", weight=2]
}
''';
      final g2 = parseDot(graphToDot(parseDot(src)));
      expect(g2.nodes['plan']!.systemPrompt, 'you plan');
      expect(g2.nodes['plan']!.modelReference, 'anthropic/sonnet');
      expect(g2.nodes['plan']!.goalGate, isTrue);
      expect(g2.nodes['plan']!.maxRetries, 3);
      final toDone = g2.outgoing('review').firstWhere((e) => e.to == 'done');
      expect(toDone.label, 'approve');
      expect(toDone.condition, 'outcome=success');
      final toPlan = g2.outgoing('review').firstWhere((e) => e.to == 'plan');
      expect(toPlan.label, 'revise');
      expect(toPlan.weight, 2);
    });

    test('is idempotent (write(parse(write(g))) == write(g))', () {
      const src = '''
digraph I {
  graph [goal="g"]
  start [shape=Mdiamond]
  exit [shape=Msquare]
  a [shape=box, system_prompt="r", prompt="do it"]
  start -> a -> exit
}
''';
      final w1 = graphToDot(parseDot(src));
      final w2 = graphToDot(parseDot(w1));
      expect(w2, w1);
    });

    test('sanitizes a node id that is not a bare identifier', () {
      final g = parseDot('digraph X { start [shape=Mdiamond] exit [shape=Msquare] start -> exit }');
      // Inject a weird id programmatically; it must be sanitized to a bare id.
      g.nodes['weird id'] = PipelineNode(id: 'weird id', attrs: {'shape': 'box'});
      g.edges.add(PipelineEdge(from: 'start', to: 'weird id'));
      final out = graphToDot(g);
      expect(out, contains('weird_id'));
      final g2 = parseDot(out);
      expect(g2.nodes.containsKey('weird_id'), isTrue);
      expect(g2.outgoing('start').any((e) => e.to == 'weird_id'), isTrue);
    });
  });
}
