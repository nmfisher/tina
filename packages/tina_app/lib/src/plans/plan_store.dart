import 'dart:async';

/// One item of a conversation's plan.
enum PlanState { pending, inProgress, done }

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
  final List<({String text, PlanState state})> items;

  /// Reset to [PlanApproval.none] whenever an update changes item content
  /// (an edited plan must be re-approved); preserved for state-only flips
  /// (progress ticks must not invalidate an approval).
  final PlanApproval approval;
  const Plan(this.items, {this.approval = PlanApproval.none});

  bool get isEmpty => items.isEmpty;
  bool get isApproved => approval == PlanApproval.approved;
  bool get needsApproval => approval == PlanApproval.requested;

  /// True when [other] holds the same item content — same count, same
  /// trimmed text in the same order (states ignored). The store's
  /// "did this update edit the plan" test for approval resets.
  bool contentMatches(List<({String text, PlanState state})> other) {
    if (items.length != other.length) return false;
    for (var i = 0; i < items.length; i++) {
      if (items[i].text != other[i].text.trim()) return false;
    }
    return true;
  }

  Map<String, dynamic> toJson() => {
        'items': [
          for (final item in items)
            {'text': item.text, 'state': item.state.name},
        ],
        'approval': approval.name,
      };

  /// Lenient parse of a persisted plan blob (the session manifest's opaque
  /// `plan` entry). Never throws and always yields a valid plan: non-map
  /// entries and blank texts are skipped, unknown states fall back to
  /// pending, the item/text caps are re-applied, and the at-most-one
  /// in-progress invariant of [PlanStore.update] is re-enforced (first wins)
  /// so a corrupt manifest cannot smuggle an invalid plan past validation.
  /// An empty result carries no approval.
  factory Plan.fromJson(Map<String, dynamic> json) {
    final items = <({String text, PlanState state})>[];
    final rawItems = json['items'];
    if (rawItems is List) {
      for (final raw in rawItems) {
        if (items.length >= PlanStore.maxItems) break;
        if (raw is! Map<String, dynamic>) continue;
        var text = (raw['text'] is String ? raw['text'] as String : '').trim();
        if (text.isEmpty) continue;
        if (text.length > PlanStore.maxTextLength) {
          text = text.substring(0, PlanStore.maxTextLength);
        }
        var state =
            PlanState.values.asNameMap()[raw['state']] ?? PlanState.pending;
        if (state == PlanState.inProgress &&
            items.any((i) => i.state == PlanState.inProgress)) {
          state = PlanState.pending;
        }
        items.add((text: text, state: state));
      }
    }
    final approval =
        PlanApproval.values.asNameMap()[json['approval']] ?? PlanApproval.none;
    return Plan(items, approval: items.isEmpty ? PlanApproval.none : approval);
  }

  /// Summary for the strip and tool results: the in-progress item (if any)
  /// plus done/total counts, and the approval suffix when one is wanted.
  String get summary {
    if (items.isEmpty) return '';
    final done = items.where((i) => i.state == PlanState.done).length;
    final active = items
        .where((i) => i.state == PlanState.inProgress)
        .map((i) => i.text)
        .join(' · ');
    final counts = '$done/${items.length}';
    return [if (active.isNotEmpty) active, counts, if (needsApproval) 'needs approval']
        .join(' · ');
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
  /// at-most-one in-progress invariant; throws [ArgumentError] on violations
  /// so a malformed model call surfaces as a tool error, not silent state.
  ///
  /// Approval: an update that changes item *content* (order, text, count)
  /// resets [PlanApproval.none] — an edited plan must be re-approved. A
  /// state-only update (progress ticks) preserves the current approval.
  void update(
    String conversationId,
    List<({String text, PlanState state})> items, {
    PlanApproval approval = PlanApproval.none,
  }) {
    _ensureOpen();
    if (items.length > maxItems) {
      throw ArgumentError('plan exceeds $maxItems items');
    }
    for (final item in items) {
      final text = item.text.trim();
      if (text.isEmpty) {
        throw ArgumentError('plan items must have non-empty text');
      }
      if (text.length > maxTextLength) {
        throw ArgumentError('plan item text exceeds $maxTextLength chars');
      }
    }
    final inProgress = items.where((i) => i.state == PlanState.inProgress);
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
    _plans[conversationId] = Plan([
      for (final item in items) (text: item.text.trim(), state: item.state),
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
      _plans[conversationId] =
          Plan(plan.items, approval: value);
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
    if (a.approval != b.approval || a.items.length != b.items.length) {
      return false;
    }
    for (var i = 0; i < a.items.length; i++) {
      if (a.items[i].text != b.items[i].text ||
          a.items[i].state != b.items[i].state) {
        return false;
      }
    }
    return true;
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
