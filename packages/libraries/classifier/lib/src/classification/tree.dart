part of 'orchestrator.dart';

/// A node's own input is separate from its children. Null means no local input.
/// Keys have no filesystem meaning; '::' is reserved for stored task names.
class Node {
  final String key;
  final SourceRequest? input;
  final List<String> children;
  Node(this.key, {this.input, Iterable<String> children = const []})
    : children = List.unmodifiable(children.toList()..sort()) {
    if (key.isEmpty ||
        key.contains('::') ||
        this.children.toSet().length != this.children.length) {
      throw ArgumentError('Invalid tree node');
    }
  }
}

class TreeSnapshot {
  final String root;
  final Map<String, Node> nodes;
  final SourceRevision revision;
  final List<List<Node>> _levels;
  factory TreeSnapshot(
    String root,
    Iterable<Node> nodes,
    SourceRevision revision,
  ) {
    final all = nodes.toList();
    final byKey = {for (final node in all) node.key: node};
    if (byKey.length != all.length || !byKey.containsKey(root)) {
      throw ArgumentError('Duplicate node or missing root');
    }
    final parents = <String, String>{};
    for (final node in all) {
      for (final child in node.children) {
        if (!byKey.containsKey(child) ||
            child == root ||
            parents.containsKey(child)) {
          throw ArgumentError('Missing child, shared child or cycle');
        }
        parents[child] = node.key;
      }
    }
    final levels = <List<Node>>[];
    var level = [byKey[root]!];
    final visited = <String>{};
    while (level.isNotEmpty) {
      levels.add(List.unmodifiable(level));
      for (final node in level) {
        if (!visited.add(node.key)) throw ArgumentError('Tree cycle');
      }
      level = [
        for (final node in level)
          for (final key in node.children) byKey[key]!,
      ];
    }
    if (visited.length != all.length) throw ArgumentError('Disconnected tree');
    return TreeSnapshot._(
      root,
      Map.unmodifiable(byKey),
      revision,
      List.unmodifiable(levels.reversed),
    );
  }
  TreeSnapshot._(this.root, this.nodes, this.revision, this._levels);
}

/// Sources discover membership and decide whether it is still current.
/// Discovery must fail if the inventory is incomplete; it must not omit children.
abstract interface class TreeSource<I> implements ClassificationSource<I> {
  Future<TreeSnapshot> tree(
    SourceRequest request,
    JudgmentCancellation cancellation,
  );
  Future<bool> isTreeCurrent(
    SourceRevision revision,
    JudgmentCancellation cancellation,
  );
}

/// Exactly the data a parent consumes. Storage IDs and source receipts are
/// deliberately absent, so a reread with the same result stops invalidation.
class Part<O> {
  final String key;
  final ClassificationResult<O> result;
  final InputCoverage coverage;
  Part(this.key, this.result, this.coverage);
}

DataContract<Part<O>> partContract<O>(DataContract<O> output) => DataContract(
  id: 'classifier.part.${output.id}',
  revision: output.revision,
  schema: {
    'type': 'object',
    'properties': {
      'key': {'type': 'string'},
      'result': partialObservationContract(output).schema,
      'coverage': {'type': 'object'},
    },
    'required': ['key', 'result', 'coverage'],
    'additionalProperties': false,
  },
  encode: (v) => {
    'key': v.key,
    'result': v.result.toJson(output),
    'coverage': v.coverage.toJson(),
  },
  decode: (v) {
    final map = jsonObject(v);
    return Part(
      map['key'] as String,
      ClassificationResult.fromJson(map['result'], output),
      InputCoverage.fromJson(map['coverage']),
    );
  },
);

/// Both stages use ordinary plans, including bounded chunking or code-only
/// reductions. Factories can delegate different nodes to different classifiers.
class TreePlan<I, O> {
  final String id;
  final DataContract<O> output;
  final ClassificationPlan<I, O> Function(Node) local;
  final ClassificationPlan<Part<O>, O> Function(Node) merge;
  TreePlan({
    required this.id,
    required this.output,
    required this.local,
    required this.merge,
  }) {
    if (id.isEmpty || id.contains('::'))
      throw ArgumentError('Invalid tree plan ID');
  }
  String key(Node node) => '${node.key}::$id';
  String localKey(Node node) => '${key(node)}::local';
  Set<String> keys(TreeSnapshot tree) => {
    for (final node in tree.nodes.values) key(node),
    for (final node in tree.nodes.values)
      if (node.input != null) localKey(node),
  };
}

class TreeReport<O> extends ClassificationReport<O> {
  final Map<String, ClassificationRecord<O>> local;
  TreeReport(
    super.records,
    super.failures,
    Map<String, ClassificationRecord<O>> local,
  ) : local = Map.unmodifiable(local);
}

extension TreeSession on ClassificationSession {
  Future<TreeSnapshot> readTree<I>(
    TreeSource<I> source,
    SourceRequest request,
  ) => _bounded<TreeSnapshot>(() => source.tree(request, cancellation));

  /// Validate a completed set of locals together, including across dimensions.
  Future<void> checkTree<I>(
    TreeSource<I> source,
    TreeSnapshot tree,
    Iterable<String> localKeys,
  ) async {
    if (!await _bounded(
      () => source.isTreeCurrent(tree.revision, cancellation),
    )) {
      throw StateError('Tree changed during classification');
    }
    final checked = <String>{};
    for (final key in localKeys) {
      final saved = await _load('task:$key');
      if (saved == null) throw StateError('Missing local result: $key');
      final revision = SourceRevision(jsonObject(saved['source_revision']));
      if (!checked.add(canonicalFingerprint(revision.receipt))) continue;
      if (!await _bounded(() => source.isCurrent(revision, cancellation))) {
        throw StateError('Input changed during classification: $key');
      }
    }
  }

  /// Locals run in parallel, followed by merges from leaves to root. All work
  /// shares this session's request limits, cancellation, writer and checkpoints.
  /// Upstream inputs are per node; a failed prerequisite can block that node.
  Future<TreeReport<O>> runTree<I, O>({
    required TreeSource<I> source,
    required SourceRequest request,
    required TreePlan<I, O> plan,
    TreeSnapshot? tree,
    Map<String, Map<String, Object?>> upstream = const {},
    Set<String> blocked = const {},
  }) async {
    final view = tree ?? await readTree(source, request);
    // Contribute this tree's size to the run-wide total; multi-tree workflows
    // (locals, then per-level merges) therefore announce one tree at a time.
    announceTaskTotal(tasksTotal + plan.keys(view).length);
    final failures = <String, String>{
      for (final key in blocked) key: 'Blocked by prerequisite',
    };
    final locals = <String, ClassificationRecord<O>>{};
    final records = <String, ClassificationRecord<O>>{};
    final localTasks = <ClassificationNode<I, O>>[];
    for (final node in view.nodes.values) {
      if (node.input == null || blocked.contains(node.key)) continue;
      final localPlan = plan.local(node);
      if (contractFingerprint(localPlan.output) !=
          contractFingerprint(plan.output)) {
        throw ArgumentError('Local output contract disagrees with tree plan');
      }
      localTasks.add(
        ClassificationNode(
          plan.localKey(node),
          build: (_) => ClassificationTask(
            key: plan.localKey(node),
            request: node.input!,
            source: source,
            plan: localPlan,
            upstream: upstream[node.key] ?? const {},
          ),
        ),
      );
    }
    final localReport = await runGraph(localTasks);
    for (final node in view.nodes.values) {
      final record = localReport.records[plan.localKey(node)];
      if (record != null) locals[node.key] = record;
      final failure = localReport.failures[plan.localKey(node)];
      if (failure != null) failures[node.key] = failure;
    }
    for (final level in view._levels) {
      final tasks = <ClassificationNode<Part<O>, O>>[];
      for (final node in level) {
        if (failures.containsKey(node.key)) continue;
        if (node.children.any((key) => !records.containsKey(key))) {
          failures[node.key] = 'Blocked by child';
          continue;
        }
        final merge = plan.merge(node);
        if (contractFingerprint(merge.output) !=
            contractFingerprint(plan.output)) {
          throw ArgumentError('Merge output contract disagrees with tree plan');
        }
        final parts = <Part<O>>[
          if (locals[node.key] case final local?)
            Part(plan.localKey(node), local.result, local.coverage),
          for (final key in node.children)
            Part(key, records[key]!.result, records[key]!.coverage),
        ];
        final input = PartsSource(plan.output, parts);
        tasks.add(
          ClassificationNode(
            plan.key(node),
            build: (_) => ClassificationTask(
              key: plan.key(node),
              request: SourceRequest(node.key),
              source: input,
              plan: merge,
              upstream: upstream[node.key] ?? const {},
            ),
          ),
        );
      }
      final merged = await runGraph(tasks);
      for (final node in level) {
        final result = merged.records[plan.key(node)];
        if (result != null) records[node.key] = result;
        final failure = merged.failures[plan.key(node)];
        if (failure != null) failures[node.key] = failure;
      }
    }
    // A completed child can change while another branch is still running.
    // Revalidate the observed inputs and membership before returning a tree.
    // Checkpoints remain reusable, but stale aggregates are not reported as current.
    try {
      await checkTree(
        source,
        view,
        locals.keys.map((key) => plan.localKey(view.nodes[key]!)),
      );
    } catch (e) {
      failures[view.root] = cancellation.isCancelled ? 'Cancelled' : '$e';
      records.clear();
      locals.clear();
    }
    return TreeReport(records, failures, locals);
  }
}

/// The shared source and revision codec for merged child results. Readers can
/// use it to validate a saved merge without executing its classification plan.
class PartsSource<O> implements ClassificationSource<Part<O>> {
  @override
  final DataContract<Part<O>> contract;
  final List<Part<O>> parts;
  PartsSource(DataContract<O> output, this.parts)
    : contract = partContract(output);
  @override
  Object get identity => {'id': 'classifier.parts', 'revision': 1};
  @override
  InputSplitter<Part<O>>? get splitter => null;
  SourceRevision get revision => SourceRevision({
    'parts': [
      for (final part in parts)
        {'key': part.key, 'hash': canonicalFingerprint(contract.encode(part))},
    ],
  });
  @override
  Future<bool> isCurrent(
    SourceRevision saved,
    JudgmentCancellation cancellation,
  ) async =>
      !cancellation.isCancelled &&
      canonicalFingerprint(saved.receipt) ==
          canonicalFingerprint(revision.receipt);
  @override
  Future<SourceSnapshot<Part<O>>> snapshot(
    SourceRequest request,
    JudgmentCancellation cancellation,
  ) async => SourceSnapshot(
    units: [
      for (final part in parts)
        SourceUnit(
          'part:${part.key}',
          part,
          supportingEvidence: part.result.evidence,
        ),
    ],
    revision: revision,
    coverage: InputCoverage(
      complete: parts.every((part) => part.coverage.complete),
      gaps: [
        for (final part in parts)
          for (final gap in part.coverage.gaps) '${part.key}: $gap',
      ],
    ),
  );
}
