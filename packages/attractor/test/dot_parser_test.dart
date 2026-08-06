import 'package:attractor/attractor.dart';
import 'package:test/test.dart';

void main() {
  group('parseDot', () {
    test('parses a linear pipeline with graph attrs and chained edges', () {
      final g = parseDot('''
        digraph Simple {
          graph [goal="Run tests"]
          rankdir=LR
          start [shape=Mdiamond, label="Start"]
          exit  [shape=Msquare, label="Exit"]
          run_tests [label="Run Tests", prompt="Run the suite"]
          start -> run_tests -> exit
        }
      ''');

      expect(g.name, 'Simple');
      expect(g.goal, 'Run tests');
      expect(g.attrs['rankdir'], 'LR');
      expect(g.nodes.keys, containsAll(['start', 'exit', 'run_tests']));
      expect(g.findStartNode()?.id, 'start');
      expect(g.terminalNodes.single.id, 'exit');
      // Two chained edges.
      expect(g.edges.length, 2);
      expect(g.outgoing('run_tests').single.to, 'exit');
      expect(g.nodes['run_tests']!.prompt, 'Run the suite');
      expect(g.nodes['start']!.shape, 'Mdiamond');
    });

    test('parses typed attribute values', () {
      final g = parseDot('''
        digraph T {
          start [shape=Mdiamond]
          exit [shape=Msquare]
          n [label="N", max_retries=3, goal_gate=true, weight=5, timeout="900s", ratio=0.5]
          start -> n -> exit
        }
      ''');
      final n = g.nodes['n']!;
      expect(n.maxRetries, 3);
      expect(n.goalGate, isTrue);
      expect(n.attrs['timeout'], '900s');
      expect(n.attrs['ratio'], 0.5);
    });

    test('parses edges with condition + label + weight', () {
      final g = parseDot('''
        digraph B {
          start [shape=Mdiamond]
          exit [shape=Msquare]
          gate [shape=diamond]
          implement [label="Implement"]
          start -> implement -> gate
          gate -> exit [label="Yes", condition="outcome=success"]
          gate -> implement [label="No", condition="outcome!=success", weight=2]
        }
      ''');
      final toExit = g.outgoing('gate').firstWhere((e) => e.to == 'exit');
      expect(toExit.label, 'Yes');
      expect(toExit.condition, 'outcome=success');
      expect(toExit.hasCondition, isTrue);
      final toImpl = g.outgoing('gate').firstWhere((e) => e.to == 'implement');
      expect(toImpl.weight, 2);
    });

    test('applies node and edge default blocks', () {
      final g = parseDot('''
        digraph D {
          node [shape=box, timeout="100s"]
          edge [weight=3]
          start [shape=Mdiamond]
          exit [shape=Msquare]
          a [label="A"]
          start -> a -> exit
        }
      ''');
      expect(g.nodes['a']!.shape, 'box');
      expect(g.nodes['a']!.attrs['timeout'], '100s');
      expect(g.edges.every((e) => e.weight == 3), isTrue);
    });

    test('handles multi-line attribute blocks and comments', () {
      final g = parseDot('''
        digraph M {
          // a comment
          start [shape=Mdiamond, label="Start"]
          /* block
             comment */
          plan [
            label="Plan",
            prompt="Plan it"
          ]
          exit [shape=Msquare]
          start -> plan -> exit
        }
      ''');
      expect(g.nodes['plan']!.prompt, 'Plan it');
    });

    test('rejects undirected edges', () {
      expect(() => parseDot('digraph X { a -- b }'), throwsA(isA<DotParseError>()));
    });

    test('rejects missing digraph keyword', () {
      expect(() => parseDot('graph X { a -> b }'), throwsA(isA<DotParseError>()));
    });

    test('concatenates adjacent quoted strings (DOT feature)', () {
      final g = parseDot('''
        digraph C {
          start [shape=Mdiamond]
          exit [shape=Msquare]
          n [prompt="first part " "second part"]
          start -> n -> exit
        }
      ''');
      expect(g.nodes['n']!.prompt, 'first part second part');
    });
  });
}
