import 'package:tina_app/tina_app.dart';
import 'package:test/test.dart';

void main() {
  // Shorthand result constructors for the fake turn adapters below.
  GoalTurnResult ok() => const GoalTurnComplete();
  GoalTurnResult abort([String? ask]) => GoalTurnAborted(permissionAsk: ask);

  ({GoalVerdict verdict, String evidence}) verdict(
    GoalVerdict v, [
    String evidence = 'evidence',
  ]) => (verdict: v, evidence: evidence);

  /// A runner whose turns always "complete", with a programmable verdict
  /// sequence (cycled when exhausted) and an optional abort on turn N.
  GoalLoopRunner runner({
    String goal = 'g',
    int maxTurns = 10,
    required List<({GoalVerdict verdict, String evidence})?> judgeAnswers,
    GoalTurnResult Function(int turn)? onTurn,
    List<String>? turnsRun,
    void Function(int)? onTurnSink,
  }) {
    var i = 0;
    return GoalLoopRunner(
      goalText: goal,
      maxTurns: maxTurns,
      runTurn: (input) async {
        turnsRun?.add(input);
        return onTurn?.call(turnsRun?.length ?? 0) ?? ok();
      },
      judge: ({required goalText, required digest}) async =>
          judgeAnswers[i++ % judgeAnswers.length],
      buildDigest: () => 'digest',
      onTurn: onTurnSink,
    );
  }

  group('GoalLoopRunner', () {
    test('judge says achieved on turn 1 → achieved, single turn', () async {
      var turns = 0;
      final r = runner(
        judgeAnswers: [verdict(GoalVerdict.achieved)],
        onTurn: (_) {
          turns++;
          return ok();
        },
      );
      expect(await r.run(), GoalLoopOutcome.achieved);
      expect(turns, 1);
    });

    test('in-progress then achieved loops with a nudge carrying evidence', () async {
      final inputs = <String>[];
      final r = GoalLoopRunner(
        goalText: 'fix the flaky test',
        maxTurns: 5,
        runTurn: (input) async {
          inputs.add(input);
          return ok();
        },
        judge: ({required goalText, required digest}) async => switch (inputs
            .length) {
          1 => verdict(GoalVerdict.inProgress, 'tests still failing'),
          _ => verdict(GoalVerdict.achieved, 'tests pass'),
        },
        buildDigest: () => 'digest',
      );
      expect(await r.run(), GoalLoopOutcome.achieved);
      expect(inputs, hasLength(2));
      expect(inputs.first, 'fix the flaky test');
      expect(inputs.last, contains('tests still failing'));
      expect(inputs.last, contains('No user is present'));
    });

    test('cap reached without an achieved verdict → capReached', () async {
      final r = runner(
        maxTurns: 3,
        judgeAnswers: [verdict(GoalVerdict.inProgress)],
      );
      expect(await r.run(), GoalLoopOutcome.capReached);
    });

    test('maxTurns 0 loops until the judge says achieved', () async {
      var calls = 0;
      final r = GoalLoopRunner(
        goalText: 'g',
        maxTurns: 0,
        runTurn: (_) async {
          calls++;
          return ok();
        },
        judge: ({required goalText, required digest}) async =>
            calls < 4 ? verdict(GoalVerdict.inProgress) : verdict(
              GoalVerdict.achieved,
            ),
        buildDigest: () => 'd',
      );
      expect(await r.run(), GoalLoopOutcome.achieved);
      expect(calls, 4);
    });

    test('unclear verdicts keep looping like in-progress', () async {
      final r = runner(
        maxTurns: 2,
        judgeAnswers: [verdict(GoalVerdict.uncertain)],
      );
      expect(await r.run(), GoalLoopOutcome.capReached);
    });

    test('judge failure once is survivable; cap counts consecutive only', () async {
      final r = runner(
        maxTurns: 4,
        judgeAnswers: [
          null, // fail 1
          null, // fail 2 — would trip a cumulative counter
          verdict(GoalVerdict.inProgress), // reset
          verdict(GoalVerdict.achieved), // done
        ],
      );
      expect(await r.run(), GoalLoopOutcome.achieved);
    });

    test('maxJudgeFailures consecutive judge failures → judgeUnavailable', () async {
      final r = runner(maxTurns: 10, judgeAnswers: [null]);
      expect(await r.run(), GoalLoopOutcome.judgeUnavailable);
    });

    test('turn abort without a permission ask → aborted (exit 2 posture)', () async {
      final r = runner(
        judgeAnswers: [verdict(GoalVerdict.achieved)],
        onTurn: (_) => abort(),
      );
      expect(await r.run(), GoalLoopOutcome.aborted);
    });

    test('turn abort from an approval ask → permissionBlocked', () async {
      final r = runner(
        judgeAnswers: [verdict(GoalVerdict.achieved)],
        onTurn: (_) =>
            abort('bash: write to /etc/hosts (deny rule: permissions.file)'),
      );
      expect(await r.run(), GoalLoopOutcome.permissionBlocked);
    });

    test('achieved verdict never runs another turn', () async {
      final inputs = <String>[];
      final r = GoalLoopRunner(
        goalText: 'g',
        maxTurns: 9,
        runTurn: (input) async {
          inputs.add(input);
          return ok();
        },
        judge: ({required goalText, required digest}) async =>
            verdict(GoalVerdict.achieved),
        buildDigest: () => 'd',
      );
      expect(await r.run(), GoalLoopOutcome.achieved);
      expect(inputs, hasLength(1));
    });
  });

  group('goalContinuationNudge', () {
    test('carries evidence and the no-user expectation', () {
      final nudge = goalContinuationNudge('two tests still red');
      expect(nudge, contains('two tests still red'));
      expect(nudge, contains('No user is present'));
    });
  });
}
