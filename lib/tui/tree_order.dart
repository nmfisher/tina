/// Pure tree-ordering helpers for the spawned-panel layout. No terminal or UI
/// dependencies, so they're unit-testable without a screen or overlays.
///
/// The right column holds spawned conversations (each a [ConversationPanel]).
/// Every panel knows its parent (the conversation that spawned it), so the
/// column can be laid out as a tree: a child sits below — and indented to the
/// right of — its parent. These functions compute that order and the per-depth
/// indent, independent of any rendering.

/// Depth-first pre-order over a forest rooted at [rootId].
///
/// Each item reports its own id via [idOf] and its parent id (or null) via
/// [parentOf]. Children are visited in their [items] insertion order, so the
/// result is deterministic and preserves spawn order among siblings. Every
/// item appears exactly once. An item whose parent is neither [rootId] nor a
/// known item id is treated as a direct child of [rootId] (a dangling edge
/// can't break the walk).
List<T> orderByTree<T>({
  required List<T> items,
  required String rootId,
  required String Function(T) idOf,
  required String? Function(T) parentOf,
}) {
  // parentId -> children, in insertion order.
  final childMap = <String, List<T>>{};
  for (final item in items) {
    final parent = parentOf(item) ?? rootId;
    childMap.putIfAbsent(parent, () => []).add(item);
  }

  final out = <T>[];
  void visit(String id) {
    for (final child in childMap[id] ?? <T>[]) {
      out.add(child);
      visit(idOf(child));
    }
  }

  visit(rootId);
  // Guard against cycles (a malformed parent link could loop): if the walk
  // didn't reach every item, append the stragglers in insertion order so the
  // caller still sees all panels.
  if (out.length != items.length) {
    final seen = <String>{for (final i in out) idOf(i)};
    for (final item in items) {
      if (!seen.contains(idOf(item))) out.add(item);
    }
  }
  return out;
}

/// Columns a panel's left border is shifted right, given its tree [depth].
///
/// The right column starts at depth ≥ 1 (depth 0 is the primary, drawn in the
/// left column), so depth 1 is flush (indent 0) and each deeper level adds 2
/// columns. Depths ≤ 1 clamp to 0.
int indentForDepth(int depth) => (depth - 1).clamp(0, 1 << 20) * 2;
