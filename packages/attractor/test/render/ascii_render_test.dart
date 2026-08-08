import 'package:attractor/attractor.dart';
import 'package:test/test.dart';

void main() {
  group('renderGraph', () {
    test('renders node labels and a forward arrow', () {
      final g = parseDot('''
        digraph L {
          start [shape=Mdiamond, label="Start"]
          done [shape=Msquare, label="Done"]
          plan [shape=box, label="Plan", llm_model="sonnet", llm_provider="anthropic"]
          start -> plan -> done
        }
      ''');
      final r = renderGraph(g);
      final canvas = r.lines.join('\n');
      // Each label appears.
      expect(canvas, contains('Start'));
      expect(canvas, contains('Plan'));
      expect(canvas, contains('Done'));
      // A forward arrowhead is present.
      expect(canvas, contains('▶'));
      // The plan node's model is shown as the sub-line.
      expect(canvas, contains('sonnet'));
      // Centers are populated for every node.
      expect(r.centers.keys, containsAll(['start', 'plan', 'done']));
    });

    test('renders a back-edge in the labeled loop band', () {
      final g = parseDot('''
        digraph Loop {
          start [shape=Mdiamond]
          done [shape=Msquare]
          plan [shape=box, label="Plan"]
          review [shape=box, label="Review"]
          start -> plan -> review
          review -> done
          review -> plan [label="revise"]
        }
      ''');
      final r = renderGraph(g);
      final canvas = r.lines.join('\n');
      expect(canvas, contains('loops:'));
      expect(canvas, contains('revise'));
      expect(canvas, contains('Review'));
      expect(canvas, contains('Plan'));
    });

    test('marks the selected node with a double-line border', () {
      final g = parseDot('''
        digraph S {
          start [shape=Mdiamond]
          done [shape=Msquare]
          a [shape=box, label="Alpha"]
          start -> a -> done
        }
      ''');
      final unselected = renderGraph(g).lines.join('\n');
      final selected = renderGraph(g, selectedId: 'a').lines.join('\n');
      expect(unselected, isNot(contains('╔')));
      expect(selected, contains('╔'));
      expect(selected, contains('╚'));
    });

    test('marks node status with border glyphs', () {
      final g = parseDot('''
        digraph S {
          start [shape=Mdiamond]
          done [shape=Msquare]
          a [shape=box, label="Alpha"]
          b [shape=box, label="Beta"]
          c [shape=box, label="Gamma"]
          start -> a -> b -> c -> done
        }
      ''');
      final canvas = renderGraph(g, status: {
        'a': NodeRunStatus.running,
        'b': NodeRunStatus.done,
        'c': NodeRunStatus.failed,
      }).lines.join('\n');
      // running → heavy box, done → rounded box, failed → double box.
      expect(canvas, contains('┏'));
      expect(canvas, contains('┛'));
      expect(canvas, contains('╭'));
      expect(canvas, contains('╰'));
      expect(canvas, contains('╔'));
      expect(canvas, contains('╝'));
      // pending (start/done) stays plain.
      expect(canvas, contains('┌'));
      expect(canvas, contains('└'));
    });

    test('selected wins over a status border (mutually exclusive in practice)',
        () {
      final g = parseDot('''
        digraph S {
          start [shape=Mdiamond]
          done [shape=Msquare]
          a [shape=box, label="Alpha"]
          start -> a -> done
        }
      ''');
      // A running node would render heavy (┏); selection renders double (╔) —
      // so the double border proves selection won.
      final canvas = renderGraph(g,
              selectedId: 'a', status: {'a': NodeRunStatus.running})
          .lines
          .join('\n');
      expect(canvas, contains('╔'));
      expect(canvas, isNot(contains('┏')));
    });
  });
}
