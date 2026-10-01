import 'package:tina_engine_2/tina_engine_2.dart';

enum PlanApproval { none, requested, approved, rejected }

/// One item of the session's plan: a short title, optional summary and
/// state word. One nesting level — children must be childless; the
/// writers validate that before appending, and [PlanChangedEntry.fromJson]
/// re-enforces it so a corrupt row cannot smuggle deeper nesting in.
final class PlanEntryItem {
  /// The state words: the same vocabulary the tool schema spells.
  static const stateWords = ['pending', 'in_progress', 'done'];
  static const maxSummaryLength = 2000;

  final String text;
  final String summary;
  final String state;

  /// Subtasks. One level: children of children are rejected.
  final List<PlanEntryItem> children;

  const PlanEntryItem(this.text,
      {required this.state, this.summary = '', this.children = const []});

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

  PlanEntryItem copyWith({String? state, String? summary}) =>
      PlanEntryItem(text,
          state: state ?? this.state,
          summary: summary ?? this.summary,
          children: children);

  @override
  bool operator ==(Object other) =>
      other is PlanEntryItem &&
      text == other.text &&
      summary == other.summary &&
      state == other.state &&
      _listEquals(children, other.children);

  @override
  int get hashCode =>
      Object.hash(text, summary, state, Object.hashAll(children));

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
final class PlanChangedEntry extends PluginStateEntry {
  static bool matches(SessionEntry entry) =>
      entry is PluginStateEntry &&
      entry.pluginId == 'tina/plans' &&
      entry.stateKey == 'plan';
  static PlanChangedEntry decode(PluginStateEntry entry) {
    if (!matches(entry) || entry.schemaVersion != 1)
      throw FormatException(
          'Unsupported tina/plans state version ${entry.schemaVersion}');
    return fromJson(
        entry.value ?? {'items': [], 'approval': 'none'}, entry.at, entry.seq);
  }

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
  String get pluginId => 'tina/plans';
  @override
  String get stateKey => 'plan';
  @override
  int get schemaVersion => 1;

  @override
  Map<String, dynamic> get value => {
        'items': [
          for (final i in items) _itemToJson(i),
        ],
        'approval': approval.name,
      };

  static Map<String, dynamic> _itemToJson(PlanEntryItem item) => {
        'text': item.text,
        'state': item.state,
        if (item.summary.isNotEmpty) 'summary': item.summary,
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
    final summary = j.containsKey('summary') ? j['summary'] : '';
    if (text is! String || state is! String) {
      throw const FormatException('plan item requires text and state');
    }
    if (summary is! String || summary.length > PlanEntryItem.maxSummaryLength) {
      throw const FormatException(
          'plan item summary must be a string of at most 2000 chars');
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
        state: PlanEntryItem.validateState(state),
        summary: summary,
        children: children);
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

extension PlansProjection on DerivedSession {
  SessionPlan? get plan {
    final raw = pluginStates['tina/plans']?['plan'];
    if (raw == null || raw.value == null) return null;
    final e = PlanChangedEntry.decode(raw);
    return SessionPlan(items: e.items, approval: e.approval);
  }
}
