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

    test('warns on an unknown role when knownRoles provided', () {
      final g = parseDot('''
        digraph X {
          start [shape=Mdiamond]
          exit [shape=Msquare]
          n [shape=box, role="nonexistent"]
          start -> n -> exit
        }
      ''');
      final d = validate(g, knownRoles: {'orchestrator', 'implementer'});
      expect(d.any((e) => e.rule == 'role_unknown' && e.severity == Severity.warning),
          isTrue);
    });

    test('a valid graph produces no errors', () {
      final g = parseDot('''
        digraph X {
          start [shape=Mdiamond]
          exit [shape=Msquare]
          a [shape=box, role="implementer"]
          start -> a -> exit
        }
      ''');
      expect(validate(g, knownRoles: {'implementer'}).where((e) => e.severity == Severity.error),
          isEmpty);
    });

    test('validateOrRaise throws on errors', () {
      final g = parseDot('digraph X { a -> b }');
      expect(() => validateOrRaise(g), throwsArgumentError);
    });
  });
}
