/// The session log's entry types and the one derive function.
///
/// The log is append-only and the loop is its only writer; every fact the
/// session needs later lives in one of the cases below. The rule for
/// whether a fact needs an entry: if a plugin's effect can be recomputed
/// from the log plus session settings, no entry — if it cannot, append
/// one. That is why the raw input is always recorded (no derivation can
/// reproduce the words as typed) and why a plugin rewrite, a mode flip
/// and a compaction each get their own entry (the plugin's rule, the
/// operator's hand and the dropped text are all unrecoverable).
///
/// `seq` equals the entry's position in the log. A gap means corruption;
/// deletion is impossible by construction — the store appends only.
///
/// Every entry round-trips through JSON as one object, so a JSON Lines
/// file and the SQLite entry log write the same bytes.
library;

import 'dart:convert';

import 'message.dart';
import 'stream.dart';

/// Why a turn stopped. The loop's stop vocabulary, owned here so an
/// entry can carry it without the core depending on a loop package.
enum TurnStopReason { complete, cancelled, error }

/// The approval dimension of the session's plan, carried on
/// [PlanChangedEntry]. The agent moves a plan to [requested] (the
/// `update_plan` tool's `approval` field) when it wants sign-off before
/// executing; only the user moves it to [approved] or [rejected] (the
/// `/plan` command). [none] is the default and also what an edited plan
/// falls back to — an edited plan must be re-approved.
enum PlanApproval { none, requested, approved, rejected }

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
final class GoalChangedEntry extends SessionEntry {
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
  String get kind => kindName;

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'text': text,
        'verdict': verdict.name,
        'evidence': evidence,
        if (at.isNotEmpty) 'at': at,
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

/// One item of the session's plan, as the log carries it: the text and
/// the state word. One nesting level — children must be childless; the
/// writers validate that before appending, and [PlanChangedEntry.fromJson]
/// re-enforces it so a corrupt row cannot smuggle deeper nesting in.
final class PlanEntryItem {
  /// The state words: the same vocabulary the tool schema spells.
  static const stateWords = ['pending', 'in_progress', 'done'];

  final String text;
  final String state;

  /// Subtasks. One level: children of children are rejected.
  final List<PlanEntryItem> children;

  const PlanEntryItem(this.text,
      {required this.state, this.children = const []});

  /// The `update_plan` wire shape for [state], validated before an entry
  /// carries it. Throws on anything else — a state the tool never wrote
  /// must not silently become `pending`.
  static String validateState(String state) {
    if (!stateWords.contains(state)) {
      throw FormatException(
          'plan item state must be one of ${stateWords.join(", ")}');
    }
    return state;
  }

  PlanEntryItem copyWith({String? state}) =>
      PlanEntryItem(text, state: state ?? this.state, children: children);

  @override
  bool operator ==(Object other) =>
      other is PlanEntryItem &&
      text == other.text &&
      state == other.state &&
      _listEquals(children, other.children);

  @override
  int get hashCode => Object.hash(text, state, Object.hashAll(children));

  @override
  String toString() => 'PlanEntryItem($state, $text'
      '${children.isEmpty ? '' : ', ${children.length} children'})';
}

bool _listEquals(List<PlanEntryItem> a, List<PlanEntryItem> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The conversation's task plan changed: this entry **is** the plan, the
/// whole current state carried forward — the latest one in the log wins,
/// and a resume derives from it the same way the running session does.
/// Nothing else about a plan is derivable (the model's reasons, the user's
/// edits mid-run), which is why the state itself is logged rather than
/// recomputed.
///
/// The shape is deliberately structured — items, each with a state word,
/// plus the approval dimension — not one text blob: the prompt section, a
/// future overlay and an auditor all read the same structured fact, and
/// the at-most-one-in-progress rule is checkable against the entry instead
/// of trusted from the writer.
final class PlanChangedEntry extends SessionEntry {
  static const kindName = 'plan_changed';

  /// The complete item list this entry installs. Empty list = plan cleared.
  final List<PlanEntryItem> items;

  /// The user-approval dimension. The writer resolves the
  /// edit-resets-approval rule (the plugin's store) before appending, so
  /// derive replays it verbatim — one authority, not two.
  final PlanApproval approval;

  final String at;

  const PlanChangedEntry({
    required this.items,
    this.approval = PlanApproval.none,
    this.at = '',
    super.seq = 0,
  });

  @override
  PlanChangedEntry withSeq(int newSeq) => PlanChangedEntry(
        items: items,
        approval: approval,
        at: at,
        seq: newSeq,
      );

  @override
  String get kind => kindName;

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'items': [
          for (final i in items) _itemToJson(i),
        ],
        'approval': approval.name,
        if (at.isNotEmpty) 'at': at,
      };

  static Map<String, dynamic> _itemToJson(PlanEntryItem item) => {
        'text': item.text,
        'state': item.state,
        if (item.children.isNotEmpty)
          'children': [for (final c in item.children) _itemToJson(c)],
      };

  /// The item cap a decoded entry enforces — a corrupt row is a reader
  /// error, not a plan. The plugin's store applies the same cap before
  /// anything is appended.
  static const maxItems = 64;

  /// Strict-but-bounded decode: unknown states throw (the tool never
  /// wrote them), depth beyond one level of children throws (the writer
  /// validated the same rule), and the item cap holds.
  static PlanChangedEntry fromJson(
    Map<String, dynamic> j,
    String at,
    int seq,
  ) {
    final rawItems = j['items'];
    if (rawItems is! List) {
      throw const FormatException('plan_changed requires an items array');
    }
    if (rawItems.length > maxItems) {
      throw const FormatException('plan_changed exceeds the item cap');
    }
    final approvalName = j['approval'] as String?;
    final approval = approvalName == null
        ? PlanApproval.none
        : PlanApproval.values.asNameMap()[approvalName] ??
            (throw FormatException('unknown plan approval: $approvalName'));
    return PlanChangedEntry(
      items: [
        for (final raw in rawItems) _itemFromJson(raw as Map<String, dynamic>),
      ],
      approval: approval,
      at: at,
    ).withSeq(seq);
  }

  static PlanEntryItem _itemFromJson(Map<String, dynamic> j,
      {bool allowChildren = true}) {
    final text = j['text'];
    final state = j['state'];
    if (text is! String || state is! String) {
      throw const FormatException('plan item requires text and state');
    }
    final rawChildren = j['children'];
    final children = <PlanEntryItem>[];
    if (rawChildren != null) {
      if (!allowChildren) {
        throw const FormatException('plan supports one nesting level only');
      }
      if (rawChildren is! List) {
        throw const FormatException('plan item children must be an array');
      }
      for (final rawChild in rawChildren) {
        children.add(_itemFromJson(rawChild as Map<String, dynamic>,
            allowChildren: false));
      }
    }
    return PlanEntryItem(text,
        state: PlanEntryItem.validateState(state), children: children);
  }

  @override
  bool operator ==(Object other) =>
      other is PlanChangedEntry &&
      _listEquals(items, other.items) &&
      approval == other.approval &&
      at == other.at;

  @override
  int get hashCode => Object.hash(Object.hashAll(items), approval, at);

  @override
  String toString() =>
      'PlanChanged(${items.length} items, approval ${approval.name})';
}

/// History was compacted: derived-message positions [replacedFrom]..

/// What the providers reported using, as recorded on a [TurnEndedEntry].
/// Shaped so `TokenUsage` converts losslessly and sums additively.
final class EntryUsage {
  final int inputTokens;
  final int outputTokens;
  final int cacheCreationInputTokens;
  final int cacheReadInputTokens;

  const EntryUsage({
    this.inputTokens = 0,
    this.outputTokens = 0,
    this.cacheCreationInputTokens = 0,
    this.cacheReadInputTokens = 0,
  });

  factory EntryUsage.fromTokens(TokenUsage u) => EntryUsage(
        inputTokens: u.inputTokens,
        outputTokens: u.outputTokens,
        cacheCreationInputTokens: u.cacheCreationInputTokens,
        cacheReadInputTokens: u.cacheReadInputTokens,
      );

  EntryUsage operator +(EntryUsage other) => EntryUsage(
        inputTokens: inputTokens + other.inputTokens,
        outputTokens: outputTokens + other.outputTokens,
        cacheCreationInputTokens:
            cacheCreationInputTokens + other.cacheCreationInputTokens,
        cacheReadInputTokens: cacheReadInputTokens + other.cacheReadInputTokens,
      );

  Map<String, dynamic> toJson() => {
        'input': inputTokens,
        'output': outputTokens,
        'cache_write': cacheCreationInputTokens,
        'cache_read': cacheReadInputTokens,
      };

  factory EntryUsage.fromJson(Map<String, dynamic> j) => EntryUsage(
        inputTokens: (j['input'] as num?)?.toInt() ?? 0,
        outputTokens: (j['output'] as num?)?.toInt() ?? 0,
        cacheCreationInputTokens: (j['cache_write'] as num?)?.toInt() ?? 0,
        cacheReadInputTokens: (j['cache_read'] as num?)?.toInt() ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is EntryUsage &&
      inputTokens == other.inputTokens &&
      outputTokens == other.outputTokens &&
      cacheCreationInputTokens == other.cacheCreationInputTokens &&
      cacheReadInputTokens == other.cacheReadInputTokens;

  @override
  int get hashCode => Object.hash(inputTokens, outputTokens,
      cacheCreationInputTokens, cacheReadInputTokens);

  @override
  String toString() => 'EntryUsage(in $inputTokens, out $outputTokens)';
}

/// One entry in the session log. Sealed: the case set below is the whole
/// set, and a reader switches over it exhaustively.
sealed class SessionEntry {
  const SessionEntry({this.seq = 0});

  /// The entry's position in the log. Set by the loop's single write
  /// path ([withSeq]); zero until then. Because it travels in the
  /// payload, a decoded row and the log it came from agree — a reader
  /// checking `seq == index` over a store's rows detects a gap without
  /// touching the store's own counters.
  final int seq;

  /// This case's JSON discriminator.
  String get kind;

  /// This entry with its position stamped. The loop's write path calls
  /// this once per entry; [fromJson] calls it once per decoded row.
  SessionEntry withSeq(int seq);

  /// One JSON object — the payload a store row or a JSON Lines line
  /// holds, verbatim. Carries `seq` when stamped.
  Map<String, dynamic> toJson() => {'type': kind, if (seq > 0) 'seq': seq};

  /// The entry a decoded payload named, position stamped from the
  /// payload's `seq`. An unknown `type` throws — a log this code cannot
  /// read must not be silently skimmed.
  static SessionEntry fromJson(Map<String, dynamic> j) {
    final type = j['type'] as String?;
    final at = (j['at'] as String?) ?? '';
    final stamped = (j['seq'] as num?)?.toInt() ?? 0;
    switch (type) {
      case TurnStartedEntry.kindName:
        return TurnStartedEntry(turnId: j['turn_id'] as String, at: at)
            .withSeq(stamped);
      case InputRecordedEntry.kindName:
        return InputRecordedEntry(
                turnId: j['turn_id'] as String,
                text: j['text'] as String,
                at: at)
            .withSeq(stamped);
      case InputRewrittenEntry.kindName:
        return InputRewrittenEntry(
          turnId: j['turn_id'] as String,
          pluginId: j['plugin_id'] as String,
          text: j['text'] as String,
          at: at,
        ).withSeq(stamped);
      case MessageAppendedEntry.kindName:
        return MessageAppendedEntry(
          turnId: j['turn_id'] as String,
          message:
              Message.fromJson(Map<String, dynamic>.from(j['message'] as Map)),
          at: at,
        ).withSeq(stamped);
      case TurnEndedEntry.kindName:
        return TurnEndedEntry(
          turnId: j['turn_id'] as String,
          reason: TurnStopReason.values.byName(j['reason'] as String),
          usage: EntryUsage.fromJson(
              Map<String, dynamic>.from(j['usage'] as Map? ?? const {})),
          stop: j['stop'] == null
              ? null
              : Map<String, dynamic>.from(j['stop'] as Map),
          at: at,
        ).withSeq(stamped);
      case UsageRecordedEntry.kindName:
        return UsageRecordedEntry(
          turnId: j['turn_id'] as String,
          usage:
              EntryUsage.fromJson(Map<String, dynamic>.from(j['usage'] as Map)),
          estimatedTokens: (j['estimated_tokens'] as num?)?.toInt() ?? 0,
          child: j['child'] == true,
          at: at,
          seq: stamped,
        );
      case ModeChangedEntry.kindName:
        return ModeChangedEntry(mode: j['mode'] as String, at: at)
            .withSeq(stamped);
      case CompactedEntry.kindName:
        return CompactedEntry(
          replacedFrom: (j['replaced_from'] as num).toInt(),
          replacedTo: (j['replaced_to'] as num).toInt(),
          summary: j['summary'] as String,
          at: at,
        ).withSeq(stamped);
      case PlanChangedEntry.kindName:
        return PlanChangedEntry.fromJson(j, at, stamped);
      case GoalChangedEntry.kindName:
        return GoalChangedEntry.fromJson(j, at, stamped);
      case WorkflowRunEntry.kindName:
        return WorkflowRunEntry.fromJson(j, at, stamped);
      default:
        throw FormatException('Unknown session entry type: $type');
    }
  }
}

/// A turn began. The boundary the derive function snaps to.
final class TurnStartedEntry extends SessionEntry {
  static const kindName = 'turn_started';

  /// The turn's id — the loop's `Input.id`.
  final String turnId;

  /// When the turn started, ISO-8601 UTC. Recorded, never derived from.
  final String at;

  const TurnStartedEntry({required this.turnId, this.at = '', super.seq = 0});

  @override
  TurnStartedEntry withSeq(int newSeq) =>
      TurnStartedEntry(turnId: turnId, at: at, seq: newSeq);

  @override
  String get kind => kindName;

  @override
  Map<String, dynamic> toJson() =>
      {...super.toJson(), 'turn_id': turnId, if (at.isNotEmpty) 'at': at};

  @override
  bool operator ==(Object other) =>
      other is TurnStartedEntry && turnId == other.turnId && at == other.at;

  @override
  int get hashCode => Object.hash(kindName, turnId, at);

  @override
  String toString() => 'TurnStarted($turnId)';
}

/// The human's input, exactly as typed, before any plugin touched it.
/// Always recorded — the raw words are the one thing no derivation can
/// reproduce later.
final class InputRecordedEntry extends SessionEntry {
  static const kindName = 'input_recorded';

  final String turnId;

  /// The input as typed.
  final String text;

  final String at;

  const InputRecordedEntry({
    required this.turnId,
    required this.text,
    this.at = '',
    super.seq = 0,
  });

  @override
  InputRecordedEntry withSeq(int newSeq) =>
      InputRecordedEntry(turnId: turnId, text: text, at: at, seq: newSeq);

  @override
  String get kind => kindName;

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'turn_id': turnId,
        'text': text,
        if (at.isNotEmpty) 'at': at,
      };

  @override
  bool operator ==(Object other) =>
      other is InputRecordedEntry &&
      turnId == other.turnId &&
      text == other.text &&
      at == other.at;

  @override
  int get hashCode => Object.hash(kindName, turnId, text, at);

  @override
  String toString() => 'InputRecorded($turnId, "$text")';
}

/// A plugin replaced the input. A rewrite cannot be recomputed — the
/// plugin's rule is its own — so it gets this entry, naming the plugin.
/// The message the provider eventually sees carries the rewritten text;
/// the raw words stay in [InputRecordedEntry].
final class InputRewrittenEntry extends SessionEntry {
  static const kindName = 'input_rewritten';

  final String turnId;

  /// The plugin that did the rewriting.
  final String pluginId;

  /// The input after the rewrite.
  final String text;

  final String at;

  const InputRewrittenEntry({
    required this.turnId,
    required this.pluginId,
    required this.text,
    this.at = '',
    super.seq = 0,
  });

  @override
  InputRewrittenEntry withSeq(int newSeq) => InputRewrittenEntry(
      turnId: turnId, pluginId: pluginId, text: text, at: at, seq: newSeq);

  @override
  String get kind => kindName;

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'turn_id': turnId,
        'plugin_id': pluginId,
        'text': text,
        if (at.isNotEmpty) 'at': at,
      };

  @override
  bool operator ==(Object other) =>
      other is InputRewrittenEntry &&
      turnId == other.turnId &&
      pluginId == other.pluginId &&
      text == other.text &&
      at == other.at;

  @override
  int get hashCode => Object.hash(kindName, turnId, pluginId, text, at);

  @override
  String toString() => 'InputRewritten($turnId, by $pluginId, "$text")';
}

/// One message entered the conversation — the user input as the turn
/// finally took it (rewrites included), the model's replies, and the
/// paired tool results. This is the log's only transcript content:
/// derive walks these.
final class MessageAppendedEntry extends SessionEntry {
  static const kindName = 'message_appended';

  /// The turn the message belongs to.
  final String turnId;

  /// The message, in the core's own JSON shape — the same bytes the
  /// wire and any older transcript already use.
  final Message message;

  final String at;

  const MessageAppendedEntry({
    required this.turnId,
    required this.message,
    this.at = '',
    super.seq = 0,
  });

  @override
  MessageAppendedEntry withSeq(int newSeq) => MessageAppendedEntry(
      turnId: turnId, message: message, at: at, seq: newSeq);

  @override
  String get kind => kindName;

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'turn_id': turnId,
        'message': message.toJson(),
        if (at.isNotEmpty) 'at': at,
      };

  @override
  bool operator ==(Object other) =>
      other is MessageAppendedEntry &&
      turnId == other.turnId &&
      at == other.at &&
      message.role == other.message.role &&
      message.isSynthetic == other.message.isSynthetic &&
      _blocksEqual(message.content, other.message.content);

  static bool _blocksEqual(List<ContentBlock> a, List<ContentBlock> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (jsonEncode(a[i].toJson()) != jsonEncode(b[i].toJson())) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(kindName, turnId, at);

  @override
  String toString() =>
      'MessageAppended($turnId, ${message.role}, ${message.content.length} blocks)';
}

/// A turn ended: why, and what the providers reported using across the
/// turn's requests — the session-level number a spend view reads.
final class TurnEndedEntry extends SessionEntry {
  static const kindName = 'turn_ended';

  final String turnId;

  final TurnStopReason reason;

  final EntryUsage usage;

  final String at;

  /// Optional plugin termination metadata. Older readers ignore this field;
  /// the wire reason remains cancelled for backward compatibility.
  final Map<String, dynamic>? stop;

  const TurnEndedEntry({
    required this.turnId,
    required this.reason,
    this.usage = const EntryUsage(),
    this.at = '',
    this.stop,
    super.seq = 0,
  });

  @override
  TurnEndedEntry withSeq(int newSeq) => TurnEndedEntry(
      turnId: turnId,
      reason: reason,
      usage: usage,
      at: at,
      stop: stop,
      seq: newSeq);

  @override
  String get kind => kindName;

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'turn_id': turnId,
        'reason': reason.name,
        'usage': usage.toJson(),
        if (stop != null) 'stop': stop,
        if (at.isNotEmpty) 'at': at,
      };

  @override
  bool operator ==(Object other) =>
      other is TurnEndedEntry &&
      turnId == other.turnId &&
      reason == other.reason &&
      usage == other.usage &&
      at == other.at &&
      jsonEncode(stop) == jsonEncode(other.stop);

  @override
  int get hashCode =>
      Object.hash(kindName, turnId, reason, usage, at, jsonEncode(stop));

  @override
  String toString() => 'TurnEnded($turnId, ${reason.name})';
}

/// One settled provider attempt. Accounting is separate from the transcript:
/// retries, cancellations and children may spend tokens without a reply.
/// Provider plugins record these through the loop's single writer.
final class UsageRecordedEntry extends SessionEntry {
  static const kindName = 'usage_recorded';
  const UsageRecordedEntry(
      {required this.turnId,
      this.usage = const EntryUsage(),
      this.estimatedTokens = 0,
      this.child = false,
      this.at = '',
      super.seq});
  final String turnId;
  final EntryUsage usage;
  final int estimatedTokens;
  final bool child;
  final String at;
  @override
  String get kind => kindName;
  @override
  UsageRecordedEntry withSeq(int seq) => UsageRecordedEntry(
      turnId: turnId,
      usage: usage,
      estimatedTokens: estimatedTokens,
      child: child,
      at: at,
      seq: seq);
  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'turn_id': turnId,
        'usage': usage.toJson(),
        'estimated_tokens': estimatedTokens,
        'child': child,
        if (at.isNotEmpty) 'at': at
      };
  @override
  bool operator ==(Object other) =>
      other is UsageRecordedEntry &&
      turnId == other.turnId &&
      usage == other.usage &&
      estimatedTokens == other.estimatedTokens &&
      child == other.child &&
      at == other.at;
  @override
  int get hashCode =>
      Object.hash(kindName, turnId, usage, estimatedTokens, child, at);
}

/// The plan as a derivation reports it: the entry's items and approval
/// plus the derived answers (which item is in progress, the counts) the
/// prompt section and a strip both want. Value type; [PlanChangedEntry]
/// is the truth, this is its reading.
final class SessionPlan {
  final List<PlanEntryItem> items;
  final PlanApproval approval;

  const SessionPlan({required this.items, this.approval = PlanApproval.none});

  bool get isEmpty => items.isEmpty;

  bool get needsApproval => approval == PlanApproval.requested;

  bool get isApproved => approval == PlanApproval.approved;

  /// Every item, top-level rows then their children — the walk the
  /// counts and the in-progress check use.
  Iterable<PlanEntryItem> get allItems sync* {
    for (final item in items) {
      yield item;
      yield* item.children;
    }
  }

  /// The in-progress texts, in order — at most one when the writers
  /// validated, but derive does not re-trust: a corrupt hand-sewn log
  /// with two shows both rather than picking one.
  List<String> get inProgress => [
        for (final i in allItems)
          if (i.state == 'in_progress') i.text,
      ];

  int get doneCount => allItems.where((i) => i.state == 'done').length;

  @override
  bool operator ==(Object other) =>
      other is SessionPlan &&
      _listEquals(items, other.items) &&
      approval == other.approval;

  @override
  int get hashCode => Object.hash(Object.hashAll(items), approval);

  @override
  String toString() => 'SessionPlan(${items.length} items, ${doneCount} done, '
      'approval ${approval.name})';
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

/// The permission mode moved. It moves outside the loop — a slash
/// command, an operator key — so nothing about a turn recomputes it; the
/// log records it and derive reports the latest value in
/// [DerivedSession.mode].
final class ModeChangedEntry extends SessionEntry {
  static const kindName = 'mode_changed';

  /// The mode's word, as the session's vocabulary spells it (`normal`,
  /// `read-only`). A string, not an enum: the core owns no vocabulary.
  final String mode;

  final String at;

  const ModeChangedEntry({required this.mode, this.at = '', super.seq = 0});

  @override
  ModeChangedEntry withSeq(int newSeq) =>
      ModeChangedEntry(mode: mode, at: at, seq: newSeq);

  @override
  String get kind => kindName;

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'mode': mode,
        if (at.isNotEmpty) 'at': at,
      };

  @override
  bool operator ==(Object other) =>
      other is ModeChangedEntry && mode == other.mode && at == other.at;

  @override
  int get hashCode => Object.hash(kindName, mode, at);

  @override
  String toString() => 'ModeChanged($mode)';
}

/// History was compacted: derived-message positions [replacedFrom]..
/// [replacedTo] (inclusive; indexes into the derived message list **as
/// it stood when this entry was appended** — a log is replayed in order,
/// so an earlier compaction's shrinkage is already applied) are gone,
/// replaced by one synthetic user message carrying [summary]. The
/// dropped text is unrecoverable, which is exactly why this entry
/// exists: it is the one fact no derivation can reproduce.
final class CompactedEntry extends SessionEntry {
  static const kindName = 'compacted';

  /// First replaced message index.
  final int replacedFrom;

  /// Last replaced message index, inclusive.
  final int replacedTo;

  /// The summary text standing in for the replaced range.
  final String summary;

  final String at;

  const CompactedEntry({
    required this.replacedFrom,
    required this.replacedTo,
    required this.summary,
    this.at = '',
    super.seq = 0,
  });

  @override
  CompactedEntry withSeq(int newSeq) => CompactedEntry(
      replacedFrom: replacedFrom,
      replacedTo: replacedTo,
      summary: summary,
      at: at,
      seq: newSeq);

  @override
  String get kind => kindName;

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'replaced_from': replacedFrom,
        'replaced_to': replacedTo,
        'summary': summary,
        if (at.isNotEmpty) 'at': at,
      };

  @override
  bool operator ==(Object other) =>
      other is CompactedEntry &&
      replacedFrom == other.replacedFrom &&
      replacedTo == other.replacedTo &&
      summary == other.summary &&
      at == other.at;

  @override
  int get hashCode =>
      Object.hash(kindName, replacedFrom, replacedTo, summary, at);

  @override
  String toString() =>
      'Compacted($replacedFrom..$replacedTo, ${summary.length} chars)';
}

/// A workflow run as a derivation reports it: the workflow's name, how it
/// ended, its final text and the nodes that executed. Value type;
/// [WorkflowRunEntry] is the truth, this is its reading.
final class SessionWorkflowRun {
  /// How the run ended, as [WorkflowRunEntry] spells it.
  final String status;

  /// The workflow's name — the catalog name it launched under.
  final String workflow;

  /// The run's final output: the last node's response on success, the
  /// failure reason otherwise. Empty when the run produced neither.
  final String detail;

  /// The node ids that executed, in execution order.
  final List<String> nodes;

  const SessionWorkflowRun({
    required this.workflow,
    required this.status,
    this.detail = '',
    this.nodes = const [],
  });

  bool get isSuccess => status == WorkflowRunEntry.statusSuccess;

  @override
  bool operator ==(Object other) =>
      other is SessionWorkflowRun &&
      workflow == other.workflow &&
      status == other.status &&
      detail == other.detail &&
      _stringListEquals(nodes, other.nodes);

  @override
  int get hashCode =>
      Object.hash(workflow, status, detail, Object.hashAll(nodes));

  @override
  String toString() =>
      'SessionWorkflowRun($workflow, $status, ${nodes.length} nodes)';
}

bool _stringListEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// One workflow run ended. The run itself is not part of the
/// conversation — a node's work is real turns in the log, and that is
/// where its content lives — but the run's **outcome** is a whole-state
/// fact no later log reading can recompute (which graph traversal
/// produced these turns, and how the traversal ended). Like
/// [PlanChangedEntry] and [GoalChangedEntry], the entry **is** the
/// state: the latest one wins in a derive, so a resume sees the same
/// last-run summary the running session did.
///
/// The node list is an audit trail, capped by the writer; a run that
/// failed before any node executed records an empty list.
final class WorkflowRunEntry extends SessionEntry {
  static const kindName = 'workflow_run';

  /// The only status words an entry carries.
  static const statusSuccess = 'success';
  static const statusFailed = 'failed';

  /// The workflow's name — the catalog name it launched under.
  final String workflow;

  /// How the run ended: [statusSuccess] or [statusFailed].
  final String status;

  /// The run's final output: the last node's response on success, the
  /// failure reason otherwise.
  final String detail;

  /// The node ids that executed, in execution order.
  final List<String> nodes;

  final String at;

  const WorkflowRunEntry({
    required this.workflow,
    required this.status,
    this.detail = '',
    this.nodes = const [],
    this.at = '',
    super.seq = 0,
  });

  /// The writer's constructor: validates the status word and rejects an
  /// empty workflow name, so a bad append throws at the writer instead
  /// of decoding into a run nobody launched.
  factory WorkflowRunEntry.record({
    required String workflow,
    required String status,
    String detail = '',
    List<String> nodes = const [],
    String at = '',
  }) {
    if (workflow.isEmpty) {
      throw const FormatException('workflow_run requires a workflow name');
    }
    if (status != statusSuccess && status != statusFailed) {
      throw FormatException(
          'workflow_run status must be "$statusSuccess" or "$statusFailed"');
    }
    return WorkflowRunEntry(
      workflow: workflow,
      status: status,
      detail: detail,
      nodes: List.of(nodes),
      at: at,
    );
  }

  @override
  WorkflowRunEntry withSeq(int newSeq) => WorkflowRunEntry(
        workflow: workflow,
        status: status,
        detail: detail,
        nodes: nodes,
        at: at,
        seq: newSeq,
      );

  @override
  String get kind => kindName;

  @override
  Map<String, dynamic> toJson() => {
        ...super.toJson(),
        'workflow': workflow,
        'status': status,
        'detail': detail,
        'nodes': [...nodes],
        if (at.isNotEmpty) 'at': at,
      };

  /// Strict decode: the status word is validated (a corrupt row is a
  /// reader error, not a successful run) and the workflow name must be
  /// there. The node cap matches the writer's — see the plugin.
  static WorkflowRunEntry fromJson(
    Map<String, dynamic> j,
    String at,
    int seq,
  ) {
    final workflow = j['workflow'];
    final status = j['status'];
    if (workflow is! String || workflow.isEmpty) {
      throw const FormatException('workflow_run requires a workflow name');
    }
    if (status != statusSuccess && status != statusFailed) {
      throw FormatException(
          'workflow_run status must be "$statusSuccess" or "$statusFailed"');
    }
    final rawNodes = j['nodes'];
    if (rawNodes != null && rawNodes is! List) {
      throw const FormatException('workflow_run nodes must be an array');
    }
    return WorkflowRunEntry(
      workflow: workflow,
      status: status,
      detail: (j['detail'] as String?) ?? '',
      nodes: [
        for (final n in (rawNodes as List?) ?? const []) n as String,
      ],
      at: at,
    ).withSeq(seq);
  }

  @override
  bool operator ==(Object other) =>
      other is WorkflowRunEntry &&
      workflow == other.workflow &&
      status == other.status &&
      detail == other.detail &&
      _stringListEquals(nodes, other.nodes) &&
      at == other.at;

  @override
  int get hashCode =>
      Object.hash(workflow, status, detail, Object.hashAll(nodes), at);

  @override
  String toString() => 'WorkflowRun($workflow, $status, ${nodes.length} nodes)';
}

/// The per-session settings derive consults. Plain strings — the core
/// owns no mode vocabulary and no prompt text. A session restarts these;
/// the log does not carry them.
final class SessionSettings {
  /// The session's system prompt, as configured.
  final String systemPrompt;

  /// The session's permission mode as configured at start (`normal`,
  /// `read-only`, ...). The log's [ModeChangedEntry]s override this.
  final String mode;

  const SessionSettings({this.systemPrompt = '', this.mode = 'normal'});

  Map<String, dynamic> toJson() =>
      {'system_prompt': systemPrompt, 'mode': mode};

  factory SessionSettings.fromJson(Map<String, dynamic> j) => SessionSettings(
        systemPrompt: (j['system_prompt'] as String?) ?? '',
        mode: (j['mode'] as String?) ?? 'normal',
      );

  @override
  bool operator ==(Object other) =>
      other is SessionSettings &&
      systemPrompt == other.systemPrompt &&
      mode == other.mode;

  @override
  int get hashCode => Object.hash(systemPrompt, mode);

  @override
  String toString() => 'SessionSettings(${toJson()})';
}

/// What derive produced: the request-shaped view of the log.
final class DerivedSession {
  const DerivedSession({
    required this.messages,
    required this.systemPrompt,
    required this.mode,
    required this.entriesConsumed,
    this.pendingTurnId,
    this.plan,
    this.goal,
    this.workflowRun,
  });

  /// The conversation the provider should see, oldest first.
  final List<Message> messages;

  /// The system prompt: the setting (entries do not change it today).
  final String systemPrompt;

  /// The mode now: the setting, overridden by the log's latest
  /// [ModeChangedEntry].
  final String mode;

  /// How many log entries this derivation consumed — the resume point a
  /// caller streaming entries incrementally picks up from.
  final int entriesConsumed;

  /// The turn whose input was taken but whose [TurnEndedEntry] is not in
  /// the log, or null when the log ends on a completed turn. A resume
  /// replays such a turn; it must not half-send it.
  final String? pendingTurnId;

  /// The session's plan now: the latest [PlanChangedEntry]'s state, or
  /// null when the log carries none. Like the mode, it is replayed from
  /// the log — the running session and a resume read the same fact.
  final SessionPlan? plan;

  /// The session's goal now: the latest [GoalChangedEntry]'s state, or
  /// null when no goal is set (or the last entry cleared it).
  final SessionGoal? goal;

  /// The last workflow run's outcome: the latest [WorkflowRunEntry]'s
  /// state, or null when the log carries none.
  final SessionWorkflowRun? workflowRun;

  @override
  String toString() =>
      'DerivedSession(${messages.length} messages, mode $mode, '
      'consumed $entriesConsumed, pending ${pendingTurnId ?? 'none'})';
}

/// Log + settings in, request out. Pure: the same log and the same
/// settings give the same result — which is what makes a store a cache
/// of this function rather than a second truth.
///
/// The snap rule: the derived conversation ends at a turn boundary. A
/// turn that started but never ended — its [TurnEndedEntry] is not in the
/// log — contributes nothing to [DerivedSession.messages] when
/// [includePendingTurn] is false (the default): its input, rewrite and
/// messages belong to the unfinished turn, and a resume replays the turn
/// from its input instead of half-sending it. The unfinished turn's id
/// comes back as [DerivedSession.pendingTurnId] either way.
///
/// [includePendingTurn] is for the loop that *is* the writer: mid-turn,
/// the messages of the turn it is writing — the **last** open turn — are
/// exactly what the next request must carry, so that turn's slots stay
/// in. Older open turns stay out in both modes: an abandoned turn is
/// replayed from its recorded input, never half-sent.
///
/// Compaction: each [CompactedEntry] is applied in log order to the
/// message list as it stands at that point — replace positions
/// [replacedFrom, replacedTo] with the summary as one synthetic user
/// message. A summary inherits "belongs to a completed turn" from the
/// replaced range, so a summary over completed history survives the snap
/// rule, and the boundary rule still holds: compaction happens between
/// turns, and a summary is never asked to stand in for a half turn.
DerivedSession deriveSession(
  List<SessionEntry> log,
  SessionSettings settings, {
  bool includePendingTurn = false,
}) {
  // The message slots, in log order. A slot remembers the turn that was
  // in flight when it was appended; the completed-turn set decides what
  // survives the snap.
  final slots = <_Slot>[];
  var mode = settings.mode;
  final systemPrompt = settings.systemPrompt;
  final completedTurns = <String>{};
  final openTurns = <String>[];

  /// The latest plan state, replayed entry by entry — the entry carries
  /// the whole plan, so the last one wins.
  SessionPlan? plan;

  /// The latest goal state, same rule; null when none is set.
  SessionGoal? goal;

  /// The latest workflow-run outcome, same rule; null when the log
  /// carries no run.
  SessionWorkflowRun? workflowRun;

  for (final e in log) {
    switch (e) {
      case ModeChangedEntry(mode: final newMode):
        mode = newMode;
      case TurnStartedEntry(:final turnId):
        openTurns.add(turnId);
      case InputRecordedEntry() ||
            InputRewrittenEntry() ||
            UsageRecordedEntry():
        break; // audit trail; the message entries carry the transcript
      case MessageAppendedEntry():
        slots.add(_Slot(e.message, e.turnId));
      case TurnEndedEntry(:final turnId):
        completedTurns.add(turnId);
        openTurns.remove(turnId);
      case CompactedEntry(
          :final replacedFrom,
          :final replacedTo,
          :final summary
        ):
        _compact(slots, replacedFrom, replacedTo, summary);
      case PlanChangedEntry(items: final items, approval: final approval):
        plan = SessionPlan(items: List.unmodifiable(items), approval: approval);
      case GoalChangedEntry(:final text, :final verdict, :final evidence):
        goal = text.isEmpty
            ? null
            : SessionGoal(text: text, verdict: verdict, evidence: evidence);
      case WorkflowRunEntry(
          :final workflow,
          :final status,
          :final detail,
          :final nodes
        ):
        workflowRun = SessionWorkflowRun(
            workflow: workflow, status: status, detail: detail, nodes: nodes);
    }
  }
  // A turn that started but never ended — a crash mid-turn, or an
  // abandoned one — is the resume's replay target; the most recent such
  // turn is the one a resume would continue.
  final pendingTurnId = openTurns.isEmpty ? null : openTurns.last;

  final writingTurnId = openTurns.isEmpty ? null : openTurns.last;
  final messages = [
    for (final s in slots)
      if (completedTurns.contains(s.turnId) ||
          (includePendingTurn && s.turnId == writingTurnId))
        s.message,
  ];

  return DerivedSession(
    messages: messages,
    systemPrompt: systemPrompt,
    mode: mode,
    entriesConsumed: log.length,
    pendingTurnId: pendingTurnId,
    plan: plan,
    goal: goal,
    workflowRun: workflowRun,
  );
}

class _Slot {
  _Slot(this.message, this.turnId);

  Message message;

  /// The turn the message was appended under.
  String turnId;
}

/// Replace slots [from]..[to] (inclusive, into the list as it stands
/// now) with one summary slot. The summary's turn id — the thing the
/// snap rule filters on — is borrowed from the replaced range: any
/// replaced slot from a completed turn makes the summary survive; a
/// summary over nothing survives if every replaced slot survived. An
/// out-of-range compaction touches nothing (a log claiming to replace
/// history that is not there is corruption; derive stays pure and simply
/// does not invent deletions).
void _compact(List<_Slot> slots, int from, int to, String summary) {
  if (from < 0 || to < from || to >= slots.length) return;
  final completedIds = <String>{};
  for (var i = from; i <= to; i++) {
    completedIds.add(slots[i].turnId);
  }
  final summarySlot = _Slot(
    Message(
      role: Role.user,
      content: [TextBlock(summary)],
      isSynthetic: true,
    ),
    // Any turn id in the set filters the same way, so the first is as
    // good as any — the membership test is the per-id set, not one id.
    completedIds.first,
  );
  slots
    ..removeRange(from, to + 1)
    ..insert(from, summarySlot);
}
