import '../graph.dart';

/// Render direction. LR = ranks become columns (left-to-right); TB = ranks
/// become rows (top-to-bottom).
enum Direction { lr, tb }

/// The laid-out position of every node: a [rank] (the layer) and an [index]
/// within that layer (the slot). The ASCII renderer turns this into columns
/// (LR) or rows (TB). Forward edges (rank increases) are drawn inline; edges
/// that don't increase rank (back-edges / loops, e.g. reviewer→planner) are
/// flagged via [backEdges] so the renderer can route them in a separate band.
class NodeLayout {
  final Graph graph;
  final Direction direction;

  /// `ranks[r]` = node ids in layer r, in display order.
  final List<List<String>> ranks;

  /// Node id → layer index.
  final Map<String, int> rankOf;

  /// Node id → slot index within its layer.
  final Map<String, int> indexInRank;

  /// Edges (as `"from\x00to"`) that go sideways or backward (rank(to) <=
  /// rank(from)) — drawn in the loop band, never inline with forward edges.
  final Set<String> backEdges;

  NodeLayout({
    required this.graph,
    required this.direction,
    required this.ranks,
    required this.rankOf,
    required this.indexInRank,
    required this.backEdges,
  });

  int get rankCount => ranks.length;

  /// Total slots across the widest layer.
  int get maxWidth =>
      ranks.fold(0, (m, r) => r.length > m ? r.length : m);
}

/// Compute a layered layout: longest-path layering from the start node (so the
/// start sits alone in layer 0 and the exit in the last), with a barycenter
/// pass to reduce edge crossings. [direction] only tags the result; the
/// renderer applies it.
NodeLayout computeLayout(Graph graph, {Direction direction = Direction.lr}) {
  final start = graph.findStartNode();
  final nodeIds = graph.nodes.keys.toList();

  // 1. Reachability + back-edge detection via DFS from start.
  final reachable = <String>{};
  final onStack = <String>{};
  final backEdges = <String>{};
  void dfs(String id) {
    reachable.add(id);
    onStack.add(id);
    for (final e in graph.outgoing(id)) {
      if (onStack.contains(e.to)) {
        backEdges.add(_edgeKey(e.from, e.to)); // ancestor target → back-edge
      } else if (reachable.contains(e.to)) {
        // Cross/forward to an already-finished node — not a back-edge by the
        // stack test, but if it doesn't advance rank we'll reclassify below.
      } else {
        dfs(e.to);
      }
    }
    onStack.remove(id);
  }

  if (start != null) {
    dfs(start.id);
  }

  // 2. Longest-path ranking over forward edges only.
  //    Predecessors via non-back edges: an edge is "ranking" if it advances.
  //    Iterate to fixpoint (handles DAGs regardless of DFS order).
  final rank = {for (final id in reachable) id: 0};
  if (start != null) rank[start.id] = 0;
  var changed = true;
  var guard = nodeIds.length + 2;
  while (changed && guard-- > 0) {
    changed = false;
    for (final id in reachable) {
      for (final e in graph.incoming(id)) {
        if (!reachable.contains(e.from)) continue;
        if (backEdges.contains(_edgeKey(e.from, e.to))) continue;
        final proposed = (rank[e.from] ?? 0) + 1;
        if (proposed > (rank[id] ?? 0)) {
          rank[id] = proposed;
          changed = true;
        }
      }
    }
  }

  // 3. Reclassify any non-advancing reachable edge as a back-edge (loops /
  //    same-rank) so the renderer routes it in the loop band.
  for (final e in graph.edges) {
    if (!reachable.contains(e.from) || !reachable.contains(e.to)) continue;
    if ((rank[e.to] ?? 0) <= (rank[e.from] ?? 0)) {
      backEdges.add(_edgeKey(e.from, e.to));
    }
  }

  var maxRank = reachable.fold<int>(0, (m, id) => rank[id]! > m ? rank[id]! : m);

  // 4. Unreachable nodes: stack them after the reachable layers.
  final unreachable = nodeIds.where((id) => !reachable.contains(id)).toList();
  for (final id in unreachable) {
    rank[id] = ++maxRank;
  }

  // 5. Group into layers.
  final layers = <List<String>>[];
  for (final id in {...reachable, ...unreachable}) {
    final r = rank[id]!;
    while (layers.length <= r) {
      layers.add(<String>[]);
    }
    layers[r].add(id);
  }
  // Declaration order within a layer is the stable starting point.
  for (final layer in layers) {
    layer.sort((a, b) => nodeIds.indexOf(a).compareTo(nodeIds.indexOf(b)));
  }

  // 6. Barycenter ordering: a couple of passes reducing crossings by median
  //    predecessor position.
  final indexInRank = <String, int>{};
  for (var pass = 0; pass < 3; pass++) {
    for (var r = 1; r < layers.length; r++) {
      _refreshIndices(layers, indexInRank);
      layers[r].sort((a, b) {
        final ba = _barycenter(graph, a, indexInRank, backEdges);
        final bb = _barycenter(graph, b, indexInRank, backEdges);
        final c = ba.compareTo(bb);
        return c != 0 ? c : nodeIds.indexOf(a).compareTo(nodeIds.indexOf(b));
      });
    }
  }
  _refreshIndices(layers, indexInRank);

  return NodeLayout(
    graph: graph,
    direction: direction,
    ranks: layers,
    rankOf: rank,
    indexInRank: indexInRank,
    backEdges: backEdges,
  );
}

void _refreshIndices(List<List<String>> layers, Map<String, int> out) {
  for (var r = 0; r < layers.length; r++) {
    for (var i = 0; i < layers[r].length; i++) {
      out[layers[r][i]] = i;
    }
  }
}

/// Median position of [node]'s predecessors (ranking edges only). Nodes with
/// no ranking predecessor keep their current slot (declaration order).
double _barycenter(Graph g, String node, Map<String, int> indexInRank,
    Set<String> backEdges) {
  final preds = g.incoming(node).where((e) =>
      !backEdges.contains(_edgeKey(e.from, e.to)) && indexInRank.containsKey(e.from));
  final positions = preds.map((e) => indexInRank[e.from]!.toDouble()).toList();
  if (positions.isEmpty) return double.infinity; // preserve declaration order
  positions.sort();
  final mid = positions.length ~/ 2;
  return positions.length.isOdd
      ? positions[mid]
      : (positions[mid - 1] + positions[mid]) / 2;
}

String _edgeKey(String from, String to) => '$from\x00$to';
