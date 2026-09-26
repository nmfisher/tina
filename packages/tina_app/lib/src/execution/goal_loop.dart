import '../goals/goal_judge.dart';
import '../goals/goal_store.dart';

/// Outcome of a [GoalLoopRunner.run] — what bin/ maps to process exit codes.
enum GoalLoopOutcome {
  /// The goal judge ruled the goal achieved → exit 0.
  achieved,

  /// The turn cap hit without an achieved verdict → exit 1.
  capReached,

  /// A turn aborted because a tool needed an approval no one can grant
  /// (goal mode never widens permissions) → exit 3.
  permissionBlocked,

  /// The judge could not produce a verdict [GoalLoopLimits.maxJudgeFailures]
  /// times in a row → exit 1: a goal that cannot be verified cannot be known
  /// to be achieved, and an unverifiable goal must not loop forever.
  judgeUnavailable,

  /// A turn aborted for a non-permission reason (budget trip, provider error,
  /// signal) → exit 2, the same posture as an aborted `--prompt` run.
  aborted,
}

/// How one agent turn ended — the seam that lets the loop tell "ran out of
/// permission" from "ran out of luck" without knowing about hosts or tools.
sealed class GoalTurnResult {
  const GoalTurnResult();
}

/// The turn ran to completion (its outcome lives in the transcript; the judge
/// reads it from there).
class GoalTurnComplete extends GoalTurnResult {
  const GoalTurnComplete();
}

/// The turn aborted before completing.
class GoalTurnAborted extends GoalTurnResult {
  const GoalTurnAborted({this.permissionAsk});

  /// When the abort was an approval ask: what was asked (tool + permission
  /// key). Null for every other abort cause.
  final String? permissionAsk;
}

/// Nudge prepended to the next turn's user input when the judge says the goal
/// is not yet met. Carries the judge's evidence so the agent corrects course
/// on facts, not vibes.
String goalContinuationNudge(String evidence) =>
    'goal status check: not yet achieved — $evidence\n'
    'Continue working toward the goal. No user is present: do not wait for '
    'or ask a human; decide with the tools you have.';

/// The digest-based judge call ([judgeGoalCore]) — a typedef so tests can
/// stub judging without the engine.
typedef GoalJudgeCall =
    Future<({GoalVerdict verdict, String evidence})?> Function({
      required String goalText,
      required String digest,
    });

/// Caps for the goal loop.
class GoalLoopLimits {
  /// After this many judge failures in a row the loop gives up with
  /// [GoalLoopOutcome.judgeUnavailable].
  static const maxJudgeFailures = 3;
}

/// The headless goal loop (`--goal`): run agent turns until the goal judge
/// rules the goal achieved, the turn cap hits, or the run proves it lacks
/// permission. No expectation of user input anywhere in the loop.
///
/// Pure orchestration — turns and judging arrive as functions, so the loop is
/// unit-testable without a provider, host, or engine. Wire-up (seeding the
/// GoalStore, building turns, detecting approval asks, exit codes) lives in
/// `bin/tina.dart`.
class GoalLoopRunner {
  GoalLoopRunner({
    required this.goalText,
    required this.maxTurns,
    required this.runTurn,
    required this.judge,
    required this.buildDigest,
    this.onTurn,
    this.onJudgeResult,
  });

  /// The seeded goal text (the caller has already put it in the GoalStore so
  /// the goal middleware injects it into every request).
  final String goalText;

  /// Cap on agent turns; 0 = unlimited.
  final int maxTurns;

  /// Runs one agent turn with [userInput] as the user message. The adapter
  /// may decorate the input (headless summary instructions) but must not
  /// answer approval asks on the loop's behalf — an ask ends the run.
  final Future<GoalTurnResult> Function(String userInput) runTurn;

  /// The digest-based judge (typically [judgeGoalCore]).
  final GoalJudgeCall judge;

  /// Renders the current transcript for the judge.
  final String Function() buildDigest;

  /// Progress sink: before each turn, with the 1-based turn number.
  final void Function(int turn)? onTurn;

  /// Verdict sink: after each judge attempt, including null (failed or
  /// unparseable), so the caller can log judge health.
  final void Function(({GoalVerdict verdict, String evidence})?)?
  onJudgeResult;

  /// Consecutive judge failures without a parseable verdict.
  int _judgeFailures = 0;

  /// Evidence from the last successful verdict — feeds the continuation
  /// nudge (and judge-failure nudges fall back to a neutral line).
  String _lastEvidence = '(no verdict yet)';

  /// Runs the loop to an outcome. Never throws for goal-level reasons; only
  /// infrastructure errors from [runTurn]/[judge] propagate.
  Future<GoalLoopOutcome> run() async {
    var turn = 0;
    while (maxTurns == 0 || turn < maxTurns) {
      turn++;
      onTurn?.call(turn);

      final userInput = turn == 1
          ? goalText
          : goalContinuationNudge(_lastEvidence);
      final result = await runTurn(userInput);
      switch (result) {
        case GoalTurnAborted(:final permissionAsk):
          if (permissionAsk != null) {
            return GoalLoopOutcome.permissionBlocked;
          }
          // An aborted turn is evidence of nothing (the TUI judge holds the
          // same rule) — and with no verdict the loop cannot steer. Stop.
          return GoalLoopOutcome.aborted;
        case GoalTurnComplete():
          break;
      }

      final parsed = await judge(goalText: goalText, digest: buildDigest());
      onJudgeResult?.call(parsed);
      if (parsed == null) {
        _judgeFailures++;
        if (_judgeFailures >= GoalLoopLimits.maxJudgeFailures) {
          return GoalLoopOutcome.judgeUnavailable;
        }
        continue;
      }
      _judgeFailures = 0;
      _lastEvidence = parsed.evidence;
      if (parsed.verdict == GoalVerdict.achieved) {
        return GoalLoopOutcome.achieved;
      }
      // inProgress / uncertain / none: keep looping; the next turn's input
      // carries the evidence forward.
    }
    return GoalLoopOutcome.capReached;
  }
}
