import 'package:tina_engine_2/tina_engine_2.dart';

/// The goal judge's verdict on whether the session's goal has been met.
/// [none] is the fresh-goal default (never judged); [achieved] and
/// [uncertain] come from a post-turn judge check; [inProgress] is
/// recorded explicitly too, so a flip (achieved → inProgress) reads as a
/// re-opened goal, not a stale label.
enum GoalVerdict { none, inProgress, achieved, uncertain }

/// The session's goal changed: the user's stated objective plus the
/// latest judge verdict. One goal per session; the latest entry wins,
/// and an entry with an empty text clears the goal. Like the plan, the
/// entry **is** the state — the words as typed and the verdict with its
/// evidence are not derivable from anything else in the log.
final class GoalChangedEntry extends PluginStateEntry {
  static bool matches(SessionEntry entry) =>
      entry is PluginStateEntry &&
      entry.pluginId == 'tina/goals' &&
      entry.stateKey == 'goal';
  static GoalChangedEntry decode(PluginStateEntry entry) {
    if (!matches(entry) || entry.schemaVersion != 1)
      throw FormatException(
          'Unsupported tina/goals state version ${entry.schemaVersion}');
    return fromJson(entry.value ?? {'text': ''}, entry.at, entry.seq);
  }

  static const kindName = 'goal_changed';

  /// The objective as the user typed it (trimmed). Empty = cleared.
  final String text;

  /// The latest verdict. [GoalVerdict.none] = not judged yet (a new goal
  /// always starts here — a new goal is not yet judged).
  final GoalVerdict verdict;

  /// The verdict's one-line evidence, as the judge phrased it.
  final String evidence;

  final String at;

  const GoalChangedEntry({
    required this.text,
    this.verdict = GoalVerdict.none,
    this.evidence = '',
    this.at = '',
    super.seq = 0,
  });

  @override
  GoalChangedEntry withSeq(int newSeq) => GoalChangedEntry(
        text: text,
        verdict: verdict,
        evidence: evidence,
        at: at,
        seq: newSeq,
      );

  @override
  String get pluginId => 'tina/goals';
  @override
  String get stateKey => 'goal';
  @override
  int get schemaVersion => 1;

  @override
  Map<String, dynamic> get value => {
        'text': text,
        'verdict': verdict.name,
        'evidence': evidence,
      };

  /// Strict decode: the text must be a string and the verdict word one
  /// the enum spells. A cleared goal is `text: ''` — a row without
  /// `text` at all is a corrupt row, not an empty goal.
  static GoalChangedEntry fromJson(
    Map<String, dynamic> j,
    String at,
    int seq,
  ) {
    final text = j['text'];
    final verdictName = j['verdict'];
    if (text is! String) {
      throw const FormatException('goal_changed requires text');
    }
    final verdict = verdictName == null
        ? GoalVerdict.none
        : GoalVerdict.values.asNameMap()[verdictName] ??
            (throw FormatException('unknown goal verdict: $verdictName'));
    final evidence = j['evidence'];
    if (evidence != null && evidence is! String) {
      throw const FormatException('goal_changed evidence must be a string');
    }
    return GoalChangedEntry(
      text: text,
      verdict: verdict,
      evidence: evidence as String? ?? '',
      at: at,
    ).withSeq(seq);
  }

  @override
  bool operator ==(Object other) =>
      other is GoalChangedEntry &&
      text == other.text &&
      verdict == other.verdict &&
      evidence == other.evidence &&
      at == other.at;

  @override
  int get hashCode => Object.hash(kindName, text, verdict, evidence, at);

  @override
  String toString() =>
      'GoalChanged(${text.isEmpty ? '<cleared>' : text.length.toString() + ' chars'}, '
      '${verdict.name})';
}

/// The goal as a derivation reports it: the objective, the latest
/// verdict and its evidence. Value type; [GoalChangedEntry] is the
/// truth, this is its reading.
final class SessionGoal {
  final String text;
  final GoalVerdict verdict;
  final String evidence;

  const SessionGoal({
    required this.text,
    this.verdict = GoalVerdict.none,
    this.evidence = '',
  });

  bool get hasVerdict => verdict != GoalVerdict.none;

  bool get isAchieved => verdict == GoalVerdict.achieved;

  bool get isUncertain => verdict == GoalVerdict.uncertain;

  @override
  bool operator ==(Object other) =>
      other is SessionGoal &&
      text == other.text &&
      verdict == other.verdict &&
      evidence == other.evidence;

  @override
  int get hashCode => Object.hash(text, verdict, evidence);

  @override
  String toString() => 'SessionGoal(${text.length} chars, ${verdict.name})';
}

extension GoalsProjection on DerivedSession {
  SessionGoal? get goal {
    final raw = pluginStates['tina/goals']?['goal'];
    if (raw == null || raw.value == null) return null;
    final e = GoalChangedEntry.decode(raw);
    return e.text.isEmpty
        ? null
        : SessionGoal(text: e.text, verdict: e.verdict, evidence: e.evidence);
  }
}
