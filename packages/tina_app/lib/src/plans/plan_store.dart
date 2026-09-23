import 'dart:async';

/// One item of a conversation's plan.
enum PlanState { pending, inProgress, done }

/// The conversation-scoped tracker state: an ordered list of items and each
/// one's state. Immutable value; the [PlanStore] replaces plans wholesale.
class Plan {
  final List<({String text, PlanState state})> items;
  const Plan(this.items);

  bool get isEmpty => items.isEmpty;

  /// Summary for the strip and tool results: the in-progress item (if any)
  /// plus done/total counts.
  String get summary {
    if (items.isEmpty) return '';
    final done = items.where((i) => i.state == PlanState.done).length;
    final active = items
        .where((i) => i.state == PlanState.inProgress)
        .map((i) => i.text)
        .join(' · ');
    final counts = '$done/${items.length}';
    return active.isEmpty ? counts : '$active $counts';
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

  Plan read(String conversationId) => _plans[conversationId] ?? const Plan([]);

  /// Replace [conversationId]'s plan wholesale. Validates item text and the
  /// at-most-one in-progress invariant; throws [ArgumentError] on violations
  /// so a malformed model call surfaces as a tool error, not silent state.
  void update(
    String conversationId,
    List<({String text, PlanState state})> items,
  ) {
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
    _plans[conversationId] = Plan([
      for (final item in items) (text: item.text.trim(), state: item.state),
    ]);
    _changes.add(null);
  }

  void clear(String conversationId) {
    _ensureOpen();
    if (_plans.remove(conversationId) != null) _changes.add(null);
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
