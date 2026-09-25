import 'dart:async';

/// One item of a conversation's plan.
enum PlanState { pending, inProgress, done }

/// One row of a plan: its text, state, and optional subtasks. Exactly one
/// nesting level is supported — [children] items must not carry children of
/// their own ([PlanStore.update] rejects deeper shapes; [Plan.fromJson]
/// drops them). Immutable value type with deep equality so plan snapshots
/// compare structurally.
class PlanItem {
  final String text;
  final PlanState state;

  /// Subtasks of this item. Empty for a plain row. Children are full items
  /// (text + state) but must be childless.
  final List<PlanItem> children;

  const PlanItem(
    this.text, {
    this.state = PlanState.pending,
    this.children = const [],
  });

  /// Structural equality: text, state, and children (recursively).
  @override
  bool operator ==(Object other) =>
      other is PlanItem &&
      text == other.text &&
      state == other.state &&
      _listEquals(children, other.children);

  @override
  int get hashCode => Object.hash(text, state, Object.hashAll(children));

  PlanItem copyWith({
    String? text,
    PlanState? state,
    List<PlanItem>? children,
  }) => PlanItem(
    text ?? this.text,
    state: state ?? this.state,
    children: children ?? this.children,
  );

  /// True when [other] holds the same content — same trimmed text and the
  /// same child texts in the same order (states ignored). The store's
  /// "did this update edit the plan" test for approval resets.
  bool contentMatches(PlanItem other) {
    if (text.trim() != other.text.trim()) return false;
    if (children.length != other.children.length) return false;
    for (var i = 0; i < children.length; i++) {
      if (!children[i].contentMatches(other.children[i])) return false;
    }
    return true;
  }

  Map<String, dynamic> toJson() => {
    'text': text,
    'state': state.name,
    // The key is omitted for childless rows so plans without subtasks
    // persist byte-identically to pre-nesting blobs.
    if (children.isNotEmpty) 'children': [for (final c in children) c.toJson()],
  };

  /// Lenient parse of one persisted item. Blank/junk entries are skipped
  /// (returns null); unknown states fall back to pending; overlong text is
  /// capped. When [allowChildren] is false (a child row) any nested
  /// `children` payload is dropped — depth is capped at one. The at-most-one
  /// in-progress invariant is re-enforced across the whole plan via
  /// [seenInProgress] (first wins).
  static PlanItem? fromJson(
    Map<String, dynamic> raw, {
    required bool allowChildren,
    required _InProgressFlag seenInProgress,
  }) {
    var text = (raw['text'] is String ? raw['text'] as String : '').trim();
    if (text.isEmpty) return null;
    if (text.length > PlanStore.maxTextLength) {
      text = text.substring(0, PlanStore.maxTextLength);
    }
    var state = PlanState.values.asNameMap()[raw['state']] ?? PlanState.pending;
    if (state == PlanState.inProgress) {
      if (seenInProgress.value) state = PlanState.pending;
      seenInProgress.value = true;
    }
    final children = <PlanItem>[];
    final rawChildren = raw['children'];
    if (allowChildren && rawChildren is List) {
      for (final rawChild in rawChildren) {
        if (rawChild is! Map<String, dynamic>) continue;
        final child = PlanItem.fromJson(
          rawChild,
          allowChildren: false,
          seenInProgress: seenInProgress,
        );
        if (child != null) children.add(child);
      }
    }
    return PlanItem(text, state: state, children: children);
  }
}

/// Mutable cell for [PlanItem.fromJson] to thread the "some item is already
/// in progress" fact across top-level rows and their children.
class _InProgressFlag {
  bool value = false;
}

bool _listEquals(List<PlanItem> a, List<PlanItem> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// The user-approval dimension of a conversation's plan. The agent moves a
/// plan to [requested] (update_plan's `approval` field) when it wants sign-off
/// before executing; only the user moves it to [approved]/[rejected]
/// (`/plan approve|reject`, the plan overlay). [none] is the default and also
/// what an edited plan falls back to — see [PlanStore.update].
enum PlanApproval { none, requested, approved, rejected }

/// The conversation-scoped tracker state: an ordered list of items, each one's
/// state, and the approval dimension. Immutable value; the [PlanStore]
/// replaces plans wholesale.
class Plan {
  final List<PlanItem> items;

  /// Reset to [PlanApproval.none] whenever an update changes item content
  /// (an edited plan must be re-approved); preserved for state-only flips
  /// (progress ticks must not invalidate an approval).
  final PlanApproval approval;
  const Plan(this.items, {this.approval = PlanApproval.none});

  bool get isEmpty => items.isEmpty;
  bool get isApproved => approval == PlanApproval.approved;
  bool get needsApproval => approval == PlanApproval.requested;

  /// True when [other] holds the same item content — same count, same
  /// trimmed text in the same order, children included (states ignored).
  /// The store's "did this update edit the plan" test for approval resets.
  bool contentMatches(List<PlanItem> other) {
    if (items.length != other.length) return false;
    for (var i = 0; i < items.length; i++) {
      if (!items[i].contentMatches(other[i])) return false;
    }
    return true;
  }

  Map<String, dynamic> toJson() => {
    'items': [for (final item in items) item.toJson()],
    'approval': approval.name,
  };

  /// Lenient parse of a persisted plan blob (the session manifest's opaque
  /// `plan` entry). Never throws and always yields a valid plan: non-map
  /// entries and blank texts are skipped, unknown states fall back to
  /// pending, the item/text caps are re-applied, and the at-most-one
  /// in-progress invariant of [PlanStore.update] is re-enforced (first wins)
  /// so a corrupt manifest cannot smuggle an invalid plan past validation.
  /// Depth is capped at one level of children; deeper payloads are dropped.
  /// An empty result carries no approval.
  factory Plan.fromJson(Map<String, dynamic> json) {
    final items = <PlanItem>[];
    final seenInProgress = _InProgressFlag();
    final rawItems = json['items'];
    if (rawItems is List) {
      for (final raw in rawItems) {
        if (items.length >= PlanStore.maxItems) break;
        if (raw is! Map<String, dynamic>) continue;
        final item = PlanItem.fromJson(
          raw,
          allowChildren: true,
          seenInProgress: seenInProgress,
        );
        if (item != null) items.add(item);
      }
    }
    final approval =
        PlanApproval.values.asNameMap()[json['approval']] ?? PlanApproval.none;
    return Plan(items, approval: items.isEmpty ? PlanApproval.none : approval);
  }

  /// Every item of the plan, top-level rows then their children — the
  /// depth-first walk the done/total counts and in-progress checks use.
  Iterable<PlanItem> get allItems sync* {
    for (final item in items) {
      yield item;
      yield* item.children;
    }
  }

  /// Summary for the strip and tool results: the in-progress item (if any)
  /// plus done/total counts (children included), and the approval suffix
  /// when one is wanted.
  String get summary {
    if (items.isEmpty) return '';
    final done = allItems.where((i) => i.state == PlanState.done).length;
    final active = allItems
        .where((i) => i.state == PlanState.inProgress)
        .map((i) => i.text)
        .join(' · ');
    final counts = '$done/${allItems.length}';
    return [
      if (active.isNotEmpty) active,
      counts,
      if (needsApproval) 'needs approval',
    ].join(' · ');
  }
}

/// The single mutable state of the plan plugin: per-conversation plans with a
/// change stream every surface (strip, request middleware, commands) derives
/// from. Not registered as a contribution — provided as a service
/// ([planStoreServiceKey]) so sibling plugins can require it; the UI
/// subscribes through the [PlanStatusSource] contribution instead.
class PlanStore {
  final _plans = <String, Plan>{};
  final _changes = StreamController<void>.broadcast();
  var _open = true;

  /// Item/size caps, also mirrored into the tool's JSON schema.
  static const maxItems = 64;
  static const maxTextLength = 240;

  /// Host-installed persistence hook: fired after every successful mutation
  /// with the conversation id, so a plan survives `/resume` (the binder
  /// mirrors it — together with the goal — into the session manifest). Null =
  /// in-memory only (tests, unwired hosts). Implementations must not throw:
  /// the hook is fire-and-forget, called right after the change event.
  /// [hydrate] deliberately bypasses it — restoring from the manifest must
  /// not write straight back.
  void Function(String conversationId)? persistHook;

  Plan read(String conversationId) => _plans[conversationId] ?? const Plan([]);

  /// Replace [conversationId]'s plan wholesale. Validates item text and the
  /// at-most-one in-progress invariant (across top-level items *and* their
  /// children); throws [ArgumentError] on violations so a malformed model
  /// call surfaces as a tool error, not silent state. Children must be
  /// childless — deeper nesting is rejected, not silently flattened.
  ///
  /// Approval: an update that changes item *content* (order, text, count,
  /// children) resets [PlanApproval.none] — an edited plan must be
  /// re-approved. A state-only update (progress ticks) preserves the current
  /// approval.
  void update(
    String conversationId,
    List<PlanItem> items, {
    PlanApproval approval = PlanApproval.none,
  }) {
    _ensureOpen();
    if (items.length > maxItems) {
      throw ArgumentError('plan exceeds $maxItems items');
    }
    void validate(PlanItem item, {required bool isChild}) {
      final text = item.text.trim();
      if (text.isEmpty) {
        throw ArgumentError('plan items must have non-empty text');
      }
      if (text.length > maxTextLength) {
        throw ArgumentError('plan item text exceeds $maxTextLength chars');
      }
      if (isChild && item.children.isNotEmpty) {
        throw ArgumentError(
          'plan supports one nesting level only '
          '(children of children)',
        );
      }
      for (final child in item.children) {
        validate(child, isChild: true);
      }
    }

    for (final item in items) {
      validate(item, isChild: false);
    }
    final inProgress = [
      for (final item in items) ...[item, ...item.children],
    ].where((i) => i.state == PlanState.inProgress);
    if (inProgress.length > 1) {
      throw ArgumentError('at most one plan item may be in progress');
    }
    final previous = _plans[conversationId];
    // Same content → keep the approval dimension (unless the caller sets a
    // new one, e.g. requestApproval's re-write); edited content → none.
    final effectiveApproval = approval != PlanApproval.none
        ? approval
        : (previous != null && previous.contentMatches(items)
              ? previous.approval
              : PlanApproval.none);
    PlanItem normalize(PlanItem item) => PlanItem(
      item.text.trim(),
      state: item.state,
      children: [for (final c in item.children) normalize(c)],
    );
    _plans[conversationId] = Plan([
      for (final item in items) normalize(item),
    ], approval: effectiveApproval);
    _changes.add(null);
    persistHook?.call(conversationId);
  }

  /// Agent asks for sign-off (update_plan's `approval: "requested"`). No-op
  /// on an empty plan — there is nothing to approve. Returns the new value so
  /// callers can report it.
  PlanApproval requestApproval(String conversationId) =>
      _setApproval(conversationId, PlanApproval.requested);

  /// The user signs off (`/plan approve`, the plan overlay).
  PlanApproval approve(String conversationId) =>
      _setApproval(conversationId, PlanApproval.approved);

  /// The user declines (`/plan reject`, the plan overlay).
  PlanApproval reject(String conversationId) =>
      _setApproval(conversationId, PlanApproval.rejected);

  PlanApproval _setApproval(String conversationId, PlanApproval value) {
    _ensureOpen();
    final plan = _plans[conversationId];
    if (plan == null || plan.isEmpty) {
      throw StateError('no plan to approve');
    }
    if (plan.approval != value) {
      _plans[conversationId] = Plan(plan.items, approval: value);
      _changes.add(null);
      persistHook?.call(conversationId);
    }
    return value;
  }

  void clear(String conversationId) {
    _ensureOpen();
    if (_plans.remove(conversationId) != null) {
      _changes.add(null);
      persistHook?.call(conversationId);
    }
  }

  /// Restore [conversationId]'s plan from persisted manifest JSON — the
  /// startup and `/resume` path. [json] null (or a blob that parses to an
  /// empty plan) CLEARS: the manifest is authoritative over stale in-memory
  /// state. Sanitizing and total ([Plan.fromJson] re-applies every cap and
  /// invariant) and never throws — a corrupt blob must never break a resume.
  /// Bypasses [persistHook] (reading the manifest only to write it back would
  /// be a pointless echo) but does fire [changes] when the state actually
  /// changed, so a mid-session `/resume` repaints the strip.
  void hydrate(String conversationId, Map<String, dynamic>? json) {
    if (!_open) return; // disposed: hydration is best-effort, never throws.
    Plan? next;
    if (json != null) {
      try {
        next = Plan.fromJson(json);
      } catch (_) {
        next = null; // fromJson is lenient by contract; belt-and-suspenders.
      }
      if (next != null && next.isEmpty) next = null;
    }
    final prev = _plans[conversationId];
    if (next == null) {
      if (prev != null) {
        _plans.remove(conversationId);
        _changes.add(null);
      }
      return;
    }
    if (prev != null && _samePlan(prev, next)) return;
    _plans[conversationId] = next;
    _changes.add(null);
  }

  static bool _samePlan(Plan a, Plan b) {
    return a.approval == b.approval && _listEquals(a.items, b.items);
  }

  /// Fired after every successful mutation. Listeners must not throw.
  Stream<void> get changes => _changes.stream;

  void dispose() {
    _open = false;
    _plans.clear();
    _changes.close();
  }

  void _ensureOpen() {
    if (!_open) throw StateError('PlanStore disposed');
  }
}
