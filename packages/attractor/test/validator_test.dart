import 'package:attractor/attractor.dart';
import 'package:test/test.dart';

void main() {
  group('validate', () {
    test('flags a missing start node', () {
      final g = parseDot('digraph X { exit [shape=Msquare] }');
      final d = validate(g);
      expect(
          d.any((e) => e.rule == 'start_node' && e.severity == Severity.error),
          isTrue);
    });

    test('flags a missing exit node', () {
      final g = parseDot('digraph X { start [shape=Mdiamond] }');
      expect(
          validate(g).any(
              (e) => e.rule == 'terminal_node' && e.severity == Severity.error),
          isTrue);
    });

    test('flags an unreachable (orphan) node', () {
      final g = parseDot('''
        digraph X {
          start [shape=Mdiamond]
          exit [shape=Msquare]
          orphan [shape=box]
          start -> exit
        }
      ''');
      expect(
          validate(g).any((e) =>
              e.rule == 'reachability' && e.severity == Severity.error),
          isTrue);
    });

    test('a valid graph produces no errors', () {
      final g = parseDot('''
        digraph X {
          start [shape=Mdiamond]
          exit [shape=Msquare]
          a [shape=box, system_prompt="you implement", llm_model="m", llm_provider="p"]
          start -> a -> exit
        }
      ''');
      expect(validate(g).where((e) => e.severity == Severity.error), isEmpty);
    });

    test('warns on a context key that is not a node in the graph', () {
      final g = parseDot('''
        digraph X {
          start [shape=Mdiamond]
          a [shape=box]
          b [shape=box, context="plan"]
          exit [shape=Msquare]
          start -> a -> b -> exit
        }
      ''');
      final d = validate(g);
      expect(
          d.any((e) =>
              e.rule == 'context_key_unknown' &&
              e.severity == Severity.warning &&
              e.nodeId == 'b'),
          isTrue);
    });

    test('context keys naming graph nodes or engine seeds pass clean', () {
      final g = parseDot('''
        digraph X {
          start [shape=Mdiamond]
          a [shape=box, context="input,goal,history"]
          exit [shape=Msquare]
          start -> a -> exit
        }
      ''');
      expect(
          validate(g)
              .where((e) => e.rule == 'context_key_unknown'),
          isEmpty);
    });

    test('validateOrRaise throws on errors', () {
      final g = parseDot('digraph X { a -> b }');
      expect(() => validateOrRaise(g), throwsArgumentError);
    });
  });
}
