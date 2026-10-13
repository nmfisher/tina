import 'src/state.dart';
export 'src/state.dart';

/// The plan state as the plugin holds it between entries: the entry list
/// replayed. The log is the truth; this is the running session's reading
/// of it, kept current by subscribing to the loop.
class PlanState {
  final List<PlanEntryItem> items;
  final PlanApproval approval;

  PlanState({
    required List<PlanEntryItem> items,
    this.approval = PlanApproval.none,
  }) : items = List.unmodifiable(items.map(_snapshotItem));

  static PlanEntryItem _snapshotItem(PlanEntryItem item) => PlanEntryItem(
        item.text,
        state: item.state,
        summary: item.summary,
        children: List.unmodifiable(item.children.map(_snapshotItem)),
      );

  bool get isEmpty => items.isEmpty;

  bool get needsApproval => approval == PlanApproval.requested;

  bool get isApproved => approval == PlanApproval.approved;

  /// The in-progress texts, in order (at most one when validated).
  List<String> get inProgress => [
        for (final i in items) ...[
          if (i.state == 'in_progress') i.text,
          ...[
            for (final c in i.children)
              if (c.state == 'in_progress') c.text,
          ],
        ],
      ];

  /// True when the item *content* matches [other] — same count, same
  /// trimmed text and children in the same order, states ignored. The
  /// edit-resets-approval rule's test: a progress tick preserves an
  /// approval, a re-write clears it.
  bool contentMatches(List<PlanEntryItem> other) {
    if (items.length != other.length) return false;
    for (var i = 0; i < items.length; i++) {
      if (!_itemContentEquals(items[i], other[i])) return false;
    }
    return true;
  }

  static bool _itemContentEquals(PlanEntryItem a, PlanEntryItem b) {
    if (a.text.trim() != b.text.trim()) return false;
    if (a.summary.trim() != b.summary.trim()) return false;
    if (a.children.length != b.children.length) return false;
    for (var i = 0; i < a.children.length; i++) {
      if (!_itemContentEquals(a.children[i], b.children[i])) return false;
    }
    return true;
  }
}

/// Read-only plans data; readers own only their subscriptions.
abstract interface class PlanObservation {
  PlanState get state;
  String? get unavailableReason;
  void Function() listen(void Function() changed);
}
