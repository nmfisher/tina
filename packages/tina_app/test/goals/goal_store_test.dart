import 'package:tina_app/src/goals/goal_plugin.dart' show GoalSummary;
import 'package:tina_app/src/goals/goal_store.dart';
import 'package:test/test.dart';

void main() {
  group('GoalStore', () {
    test('read on an unknown conversation is the empty goal', () {
      final store = GoalStore();
      expect(store.read('c1').isEmpty, isTrue);
      store.dispose();
    });

    test('set trims, stores, and resets any previous verdict', () {
      final store = GoalStore();
      store.set('c1', '  fix the login race  ');
      expect(store.read('c1').text, 'fix the login race');
      store.recordVerdict('c1', GoalVerdict.achieved, 'tests pass');
      expect(store.read('c1').hasVerdict, isTrue);

      // A new goal is not yet judged — the old verdict must not leak.
      store.set('c1', 'ship the release');
      expect(store.read('c1').hasVerdict, isFalse);
      store.dispose();
    });

    test('set rejects empty and over-long text', () {
      final store = GoalStore();
      expect(() => store.set('c1', '   '), throwsArgumentError);
      expect(() => store.set('c1', 'x' * (GoalStore.maxTextLength + 1)),
          throwsArgumentError);
      store.dispose();
    });

    test('recordVerdict caps evidence and dedupes an unchanged verdict',
        () async {
      final store = GoalStore();
      // Setup event fires before the listener subscribes, so it is not counted.
      store.set('c1', 'goal');
      var changes = 0;
      final sub = store.changes.listen((_) => changes++);

      store.recordVerdict(
        'c1',
        GoalVerdict.achieved,
        'e' * (GoalStore.maxEvidenceLength + 50),
      );
      await Future<void>.delayed(Duration.zero);
      expect(store.read('c1').status!.evidence.length,
          GoalStore.maxEvidenceLength);
      expect(changes, 1);

      // Same verdict + evidence: no change event (the strip must not churn).
      store.recordVerdict('c1', GoalVerdict.achieved,
          'e' * GoalStore.maxEvidenceLength);
      await Future<void>.delayed(Duration.zero);
      expect(changes, 1);

      // A different verdict records and fires.
      store.recordVerdict('c1', GoalVerdict.inProgress, 'still working');
      await Future<void>.delayed(Duration.zero);
      expect(store.read('c1').status!.verdict, GoalVerdict.inProgress);
      expect(changes, 2);
      await sub.cancel();
      store.dispose();
    });

    test('recordVerdict without a goal throws StateError (the clear race)',
        () {
      final store = GoalStore();
      expect(() => store.recordVerdict('c1', GoalVerdict.achieved, 'e'),
          throwsStateError);
      store.dispose();
    });

    test('clear removes the goal and fires only when something existed',
        () async {
      final store = GoalStore();
      var changes = 0;
      final sub = store.changes.listen((_) => changes++);
      store.clear('c1');
      await Future<void>.delayed(Duration.zero);
      expect(changes, 0);
      store.set('c1', 'goal');
      store.clear('c1');
      await Future<void>.delayed(Duration.zero);
      expect(changes, 2);
      expect(store.read('c1').isEmpty, isTrue);
      await sub.cancel();
      store.dispose();
    });

    test('mutations after dispose throw', () {
      final store = GoalStore()..dispose();
      expect(() => store.set('c1', 'goal'), throwsStateError);
    });
  });

  group('GoalSummary', () {
    test('marks achieved and uncertain verdicts in the summary', () {
      const goal = Goal('ship it');
      expect(GoalSummary.fromGoal(goal).summary, 'ship it');
      expect(
        GoalSummary.fromGoal(Goal('ship it',
                status: GoalStatus(GoalVerdict.achieved,
                    evidence: 'done', at: DateTime.now())))
            .summary,
        startsWith('✓ '),
      );
      expect(
        GoalSummary.fromGoal(Goal('ship it',
                status: GoalStatus(GoalVerdict.uncertain,
                    evidence: 'maybe', at: DateTime.now())))
            .summary,
        startsWith('? '),
      );
    });

    test('long text truncates with an ellipsis', () {
      final summary = GoalSummary.fromGoal(Goal('g' * 100));
      expect(summary.summary.length, lessThan(62));
      expect(summary.summary.endsWith('…'), isTrue);
    });
  });
}
