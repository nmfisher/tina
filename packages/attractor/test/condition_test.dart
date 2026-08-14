import 'package:attractor/attractor.dart';
import 'package:test/test.dart';

void main() {
  Context ctx(Iterable<(String, String)> entries) {
    final c = Context();
    for (final (k, v) in entries) {
      c.set(k, v);
    }
    return c;
  }

  group('Condition', () {
    test('empty expression is always true', () {
      expect(evaluateCondition('', const Outcome.success(), Context()), isTrue);
    });

    test('outcome equality / inequality', () {
      final ok = const Outcome.success();
      final fail = Outcome.fail('x');
      expect(evaluateCondition('outcome=success', ok, Context()), isTrue);
      expect(evaluateCondition('outcome=success', fail, Context()), isFalse);
      expect(evaluateCondition('outcome!=success', fail, Context()), isTrue);
    });

    test('`==` parses as equality, not literal `=x`', () {
      final ok = const Outcome.success();
      expect(evaluateCondition('outcome==success', ok, Context()), isTrue);
      expect(
          evaluateCondition('outcome==success', Outcome.fail('x'), Context()),
          isFalse);
    });

    test('outcome=success treats partial_success as good enough', () {
      final partial = const Outcome(status: StageStatus.partialSuccess);
      expect(
          evaluateCondition('outcome=success', partial, Context()), isTrue);
      // Strict matching is still available the other way around…
      expect(
          evaluateCondition('outcome=partial_success',
              const Outcome.success(), Context()),
          isFalse);
      // …and != excludes partial_success from the success branch.
      expect(
          evaluateCondition('outcome!=success', partial, Context()), isFalse);
    });

    test('preferred_label match', () {
      final o = const Outcome.success(preferredLabel: 'approve');
      expect(evaluateCondition('preferred_label=approve', o, Context()), isTrue);
    });

    test('context.* lookup with and without prefix', () {
      final c = ctx([('tests_passed', 'true'), ('plan', 'v1')]);
      expect(
          evaluateCondition(
              'outcome=success && context.tests_passed=true',
              const Outcome.success(),
              c),
          isTrue);
      // Missing key compares as empty -> never equals "true".
      expect(
          evaluateCondition('context.missing=foo', const Outcome.success(), c),
          isFalse);
      expect(
          evaluateCondition('context.missing!=foo', const Outcome.success(), c),
          isTrue);
    });

    test('quoted literals are unquoted', () {
      final c = ctx([('verdict', 'needs work')]);
      expect(
          evaluateCondition('context.verdict="needs work"',
              const Outcome.success(), c),
          isTrue);
    });

    test('malformed expression does not match', () {
      expect(
          evaluateCondition('this is not valid', const Outcome.success(),
              Context()),
          isFalse);
    });
  });
}
