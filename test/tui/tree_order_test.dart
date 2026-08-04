import 'package:tina/tui/tree_order.dart';
import 'package:test/test.dart';

/// Minimal tree node for exercising [orderByTree] without any UI types.
class _Node {
  final String id;
  final String? parent;
  _Node(this.id, this.parent);
}

List<_Node> order(List<_Node> items, String rootId) => orderByTree(
      items: items,
      rootId: rootId,
      idOf: (n) => n.id,
      parentOf: (n) => n.parent,
    );

void main() {
  group('orderByTree', () {
    test('root with two children keeps insertion order', () {
      final a = _Node('a', 'root');
      final b = _Node('b', 'root');
      final out = order([a, b], 'root');
      expect(out.map((n) => n.id), ['a', 'b']);
    });

    test('DFS pre-order nests a grandchild under its parent', () {
      final a = _Node('a', 'root');
      final grandchild = _Node('g', 'a');
      final b = _Node('b', 'root');
      final out = order([a, grandchild, b], 'root');
      // a, then its subtree (g), then the sibling b.
      expect(out.map((n) => n.id), ['a', 'g', 'b']);
    });

    test('an orphan with an unknown parent is treated as a root child', () {
      final orphan = _Node('x', 'ghost');
      final out = order([orphan], 'root');
      expect(out.map((n) => n.id), ['x']);
    });

    test('every node appears exactly once (no drops, no dupes)', () {
      final a = _Node('a', 'root');
      final b = _Node('b', 'a');
      final c = _Node('c', 'b');
      final d = _Node('d', 'root');
      final out = order([a, b, c, d], 'root');
      expect(out.map((n) => n.id).toSet().length, 4);
    });

    test('a parent-link cycle cannot hang the walk', () {
      final a = _Node('a', 'b');
      final b = _Node('b', 'a');
      final out = order([a, b], 'root');
      expect(out.length, 2);
      expect(out.map((n) => n.id).toSet(), {'a', 'b'});
    });
  });

  group('indentForDepth', () {
    test('depth 1 is flush (indent 0); each deeper level adds 2', () {
      expect(indentForDepth(0), 0);
      expect(indentForDepth(1), 0);
      expect(indentForDepth(2), 2);
      expect(indentForDepth(3), 4);
      expect(indentForDepth(4), 6);
    });
  });
}
