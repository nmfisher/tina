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

  group('GoalStore persistence (JSON + hydrate)', () {
    test('Goal JSON round-trips text, verdict, evidence and timestamp', () {
      final at = DateTime(2026, 9, 24, 12, 30, 15, 123);
      final goal = Goal('ship the release',
          status: GoalStatus(GoalVerdict.achieved,
              evidence: 'tests pass', at: at));
      final back = Goal.fromJson(goal.toJson());
      expect(back.text, 'ship the release');
      expect(back.status!.verdict, GoalVerdict.achieved);
      expect(back.status!.evidence, 'tests pass');
      expect(back.status!.at, at);
    });

    test('a fresh goal serializes without the status key', () {
      expect(const Goal('plain').toJson(), {'text': 'plain'});
    });

    test('fromJson is lenient: garbage degrades, caps re-apply', () {
      expect(Goal.fromJson(const {'text': 42}).isEmpty, isTrue);
      expect(Goal.fromJson(const {'text': '  padded  '}).text, 'padded');
      expect(
          Goal.fromJson(const {
            'text': 'x',
            'status': {'verdict': 'banana', 'at': 'not-a-date'}
          }).status,
          isNull,
          reason: 'an unknown verdict degrades to no status');
      expect(
          Goal.fromJson({
            'text': 'g' * (GoalStore.maxTextLength + 50)
          }).text.length,
          GoalStore.maxTextLength);
      final capped = Goal.fromJson({
        'text': 'g',
        'status': {
          'verdict': 'achieved',
          'evidence': 'e' * (GoalStore.maxEvidenceLength + 50),
          'at': '2026-01-01T00:00:00.000Z'
        }
      });
      expect(capped.status!.evidence.length, GoalStore.maxEvidenceLength);
    });

    test('persistHook fires on mutations, never on hydrate', () {
      final store = GoalStore();
      final hooked = <String>[];
      store.persistHook = hooked.add;
      expect(() => store.set('c2', '   '), throwsArgumentError);
      store.set('c1', 'goal');
      store.recordVerdict('c1', GoalVerdict.achieved, 'done');
      store.clear('c1');
      store.clear('c1'); // nothing existed → no mutation, no hook
      expect(hooked, ['c1', 'c1', 'c1']);
      store.hydrate('c1', {'text': 'restored'});
      expect(hooked, ['c1', 'c1', 'c1'],
          reason: 'hydration IS the restore; writing back would be an echo');
      expect(store.read('c1').text, 'restored');
      store.dispose();
    });

    test('hydrate restores, repaints once, clears authoritatively, never throws',
        () async {
      final store = GoalStore();
      var changes = 0;
      final sub = store.changes.listen((_) => changes++);
      const blob = {
        'text': 'restored',
        'status': {
          'verdict': 'uncertain',
          'evidence': 'hm',
          'at': '2026-09-01T10:00:00.000Z'
        }
      };

      store.hydrate('c1', blob);
      await Future<void>.delayed(Duration.zero);
      expect(store.read('c1').text, 'restored');
      expect(store.read('c1').status!.verdict, GoalVerdict.uncertain);
      expect(store.read('c1').status!.evidence, 'hm');
      expect(changes, 1);

      store.hydrate('c1', blob); // identical → no spurious repaint
      await Future<void>.delayed(Duration.zero);
      expect(changes, 1);

      store.hydrate('c1', null); // manifest authoritative → clear
      await Future<void>.delayed(Duration.zero);
      expect(store.read('c1').isEmpty, isTrue);
      expect(changes, 2);

      store.hydrate('c1', {'text': 123}); // corrupt → degrades to clear
      expect(store.read('c1').isEmpty, isTrue);

      store.dispose();
      expect(() => store.hydrate('c1', {'text': 'x'}), returnsNormally,
          reason: 'a disposed store must not break a resume');
      await sub.cancel();
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
