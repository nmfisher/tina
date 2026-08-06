import 'package:attractor/attractor.dart';
import 'package:test/test.dart';

void main() {
  group('computeLayout', () {
    test('layers a linear pipeline by longest path', () {
      final g = parseDot('''
        digraph L {
          start [shape=Mdiamond]
          exit [shape=Msquare]
          a [shape=box] b [shape=box]
          start -> a -> b -> exit
        }
      ''');
      final l = computeLayout(g);
      expect(l.rankOf['start'], 0);
      expect(l.rankOf['a'], 1);
      expect(l.rankOf['b'], 2);
      expect(l.rankOf['exit'], 3);
      expect(l.backEdges, isEmpty);
    });

    test('classifies a reviewer->planner loop as a back-edge', () {
      final g = parseDot('''
        digraph Loop {
          start [shape=Mdiamond]
          done [shape=Msquare]
          plan [shape=box] review [shape=box] execute [shape=box]
          start -> plan -> review
          review -> execute
          review -> plan
          execute -> done
        }
      ''');
      final l = computeLayout(g);
      expect(l.rankOf['plan']!, lessThan(l.rankOf['review']!));
      expect(l.rankOf['review']!, lessThan(l.rankOf['execute']!));
      // The revise edge goes back to plan.
      expect(l.backEdges.any((k) => k.contains('review') && k.endsWith('plan')),
          isTrue);
      // The forward edge is not a back-edge.
      expect(l.backEdges.any((k) => k.contains('review') && k.endsWith('execute')),
          isFalse);
    });

    test('places unreachable nodes in trailing layers', () {
      final g = parseDot('''
        digraph U {
          start [shape=Mdiamond]
          exit [shape=Msquare]
          orphan [shape=box]
          start -> exit
        }
      ''');
      final l = computeLayout(g);
      expect(l.rankOf['orphan']!, greaterThan(l.rankOf['exit']!));
    });
  });
}
