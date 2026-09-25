import 'dart:async';

/// The judge's verdict on whether a conversation's goal has been achieved.
/// [none] is the fresh-goal default (never judged yet); [achieved] and
/// [uncertain] come from the goal judge's post-turn check; [inProgress] is
/// recorded explicitly too so a verdict flip-flop (achieved → inProgress)
/// reads as a re-opened goal, not a stale label.
enum GoalVerdict { none, inProgress, achieved, uncertain }

/// One judge run's outcome: the verdict, its one-line evidence, and when the
/// check ran. Immutable value; the [GoalStore] replaces it wholesale.
class GoalStatus {
  final GoalVerdict verdict;
  final String evidence;
  final DateTime at;
  const GoalStatus(this.verdict, {this.evidence = '', required this.at});

  bool get isAchieved => verdict == GoalVerdict.achieved;
  bool get isUncertain => verdict == GoalVerdict.uncertain;

  Map<String, dynamic> toJson() => {
    'verdict': verdict.name,
    'evidence': evidence,
    'at': at.toIso8601String(),
  };

  /// Lenient parse of a persisted status blob: an unknown verdict name, a
  /// missing/garbage `at`, or a non-map value all degrade (verdict → none →
  /// null status, timestamp → epoch) instead of throwing. The evidence cap is
  /// re-applied — an edited or hand-crafted manifest must not smuggle an
  /// unbounded string back into the strip.
  static GoalStatus? tryFromJson(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final verdict = GoalVerdict.values.asNameMap()[raw['verdict']];
    if (verdict == null || verdict == GoalVerdict.none) return null;
    var evidence = raw['evidence'] is String ? raw['evidence'] as String : '';
    if (evidence.length > GoalStore.maxEvidenceLength) {
      evidence = evidence.substring(0, GoalStore.maxEvidenceLength);
    }
    return GoalStatus(
      verdict,
      evidence: evidence,
      at:
          DateTime.tryParse('${raw['at']}') ??
          DateTime.fromMillisecondsSinceEpoch(0),
    );
  }
}

/// The conversation-scoped goal state: the objective text plus the latest
/// judge verdict. Immutable value; the [GoalStore] replaces goals wholesale.
class Goal {
  final String text;
  final GoalStatus? status;
  const Goal(this.text, {this.status});

  bool get isEmpty => text.isEmpty;
  bool get hasVerdict => status != null && status!.verdict != GoalVerdict.none;

  Map<String, dynamic> toJson() => {
    'text': text,
    if (status != null) 'status': status!.toJson(),
  };

  /// Lenient parse of a persisted goal blob (the session manifest's opaque
  /// `goal` entry). Never throws: a non-string text degrades to empty (→
  /// cleared on hydrate), an unusable status degrades to null, and the text
  /// cap is re-applied so a corrupt manifest cannot bypass [GoalStore]'s
  /// validation. The shape belongs to this store; the engine only carries it.
  factory Goal.fromJson(Map<String, dynamic> json) {
    var text = json['text'] is String ? json['text'] as String : '';
    text = text.trim();
    if (text.length > GoalStore.maxTextLength) {
      text = text.substring(0, GoalStore.maxTextLength);
    }
    return Goal(text, status: GoalStatus.tryFromJson(json['status']));
  }

  /// Summary for the strip and command echo: the goal text (truncated) and
  /// the verdict mark when one exists.
  String get summary {
    if (isEmpty) return '';
    final text = this.text.length > 60
        ? '${this.text.substring(0, 57)}…'
        : this.text;
    return switch (status?.verdict ?? GoalVerdict.none) {
      GoalVerdict.achieved => '✓ $text',
      GoalVerdict.uncertain => '? $text',
      GoalVerdict.inProgress => text,
      GoalVerdict.none => text,
    };
  }
}

/// The judge's trigger surface: resolve [conversationId]'s goal + transcript,
/// run the check, record the verdict, and return it (null when nothing ran —
/// unwired, no goal, cancelled, or the judge failed; failures are logged
/// inside, never thrown). [force] bypasses the turn-quality guard (a turn
/// that aborted must not read as "not achieved"), so `/goal check` works
/// even right after a failed turn.
typedef GoalJudgeHook =
    Future<GoalVerdict?> Function(String conversationId, {bool force});

/// The single mutable state of the goal plugin: per-conversation goals with a
/// change stream every surface (strip, request middleware, commands, the
/// turn-end judge) derives from. Not registered as a contribution — provided
/// as a service ([goalStoreServiceKey]) so sibling code can require it; the
/// UI subscribes through the [GoalStatusSource] contribution instead.
class GoalStore {
  final _goals = <String, Goal>{};
  final _changes = StreamController<void>.broadcast();
  var _open = true;

  /// The goal text cap, so one runaway objective cannot dominate every
  /// request's injected context.
  static const maxTextLength = 500;
  static const maxEvidenceLength = 240;

  /// The host-installed judge, invoked by `/goal check` and the turn-end
  /// wiring. Late-bound because only the host layer owns the pieces a judge
  /// needs — the one-shot agent scheduler, the conversation's transcript and
  /// cancel signal, and a transcript sink for notices — none of which belong
  /// in tina_app's data layer. Null = no judge this session (`/goal check`
  /// reports that instead of pretending to judge).
  GoalJudgeHook? judgeHook;

  /// Host-installed persistence hook: fired after every successful mutation
  /// with the conversation id, so a goal survives `/resume` (the binder
  /// mirrors it — together with the plan — into the session manifest). Null =
  /// in-memory only (tests, unwired hosts). Implementations must not throw:
  /// the hook is fire-and-forget, called right after the change event.
  /// [hydrate] deliberately bypasses it — restoring from the manifest must
  /// not write straight back.
  void Function(String conversationId)? persistHook;

  Goal read(String conversationId) => _goals[conversationId] ?? const Goal('');

  /// Set [conversationId]'s goal. Replaces any previous objective and resets
  /// the judge verdict — a new goal is not yet judged. Throws [ArgumentError]
  /// on empty or over-long text so command and future tool callers surface a
  /// message instead of storing silent state.
  void set(String conversationId, String text) {
    _ensureOpen();
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError('goal text must be non-empty');
    }
    if (trimmed.length > maxTextLength) {
      throw ArgumentError('goal text exceeds $maxTextLength chars');
    }
    _goals[conversationId] = Goal(trimmed);
    _changes.add(null);
    persistHook?.call(conversationId);
  }

  void clear(String conversationId) {
    _ensureOpen();
    if (_goals.remove(conversationId) != null) {
      _changes.add(null);
      persistHook?.call(conversationId);
    }
  }

  /// Record a judge verdict for [conversationId]'s goal. Throws [StateError]
  /// when no goal exists (the judge fired after the user cleared it — the
  /// race is expected and the caller swallows it). No change event when the
  /// verdict and evidence are unchanged (two judges agreeing must not spam
  /// the strip's change listeners).
  void recordVerdict(
    String conversationId,
    GoalVerdict verdict,
    String evidence,
  ) {
    _ensureOpen();
    final goal = _goals[conversationId];
    if (goal == null || goal.isEmpty) {
      throw StateError('no goal to record a verdict for');
    }
    var trimmedEvidence = evidence.trim();
    if (trimmedEvidence.length > maxEvidenceLength) {
      trimmedEvidence = trimmedEvidence.substring(0, maxEvidenceLength);
    }
    final next = GoalStatus(
      verdict,
      evidence: trimmedEvidence,
      at: DateTime.now(),
    );
    final previous = goal.status;
    if (previous != null &&
        previous.verdict == verdict &&
        previous.evidence == trimmedEvidence) {
      return;
    }
    _goals[conversationId] = Goal(goal.text, status: next);
    _changes.add(null);
    persistHook?.call(conversationId);
  }

  /// Restore [conversationId]'s goal from persisted manifest JSON — the
  /// startup and `/resume` path. [json] null (or a blob that parses to an
  /// empty goal) CLEARS: the manifest is authoritative over stale in-memory
  /// state. Sanitizing and total: unknown shapes degrade to "no goal", caps
  /// are re-applied, and nothing throws — a corrupt blob must never break a
  /// resume. Bypasses [persistHook] (reading the manifest only to write it
  /// back would be a pointless echo) but does fire [changes] when the state
  /// actually changed, so a mid-session `/resume` repaints the strip.
  void hydrate(String conversationId, Map<String, dynamic>? json) {
    if (!_open) return; // disposed: hydration is best-effort, never throws.
    Goal? next;
    if (json != null) {
      try {
        next = Goal.fromJson(json);
      } catch (_) {
        next = null; // fromJson is lenient by contract; belt-and-suspenders.
      }
      if (next != null && next.isEmpty) next = null;
    }
    final prev = _goals[conversationId];
    if (next == null) {
      if (prev != null) {
        _goals.remove(conversationId);
        _changes.add(null);
      }
      return;
    }
    if (prev != null &&
        prev.text == next.text &&
        prev.status?.verdict == next.status?.verdict &&
        prev.status?.evidence == next.status?.evidence &&
        prev.status?.at == next.status?.at) {
      return; // unchanged: no spurious repaint, no echo write.
    }
    _goals[conversationId] = next;
    _changes.add(null);
  }

  /// Fired after every successful mutation. Listeners must not throw.
  Stream<void> get changes => _changes.stream;

  void dispose() {
    _open = false;
    _goals.clear();
    _changes.close();
  }

  void _ensureOpen() {
    if (!_open) throw StateError('GoalStore disposed');
  }
}
