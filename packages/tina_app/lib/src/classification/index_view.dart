import 'dart:convert';

import 'package:classifier/classification.dart';
import 'sqlite_classification_store.dart';

import 'project_classifiers.dart';

const indexKinds = ['language', 'framework', 'tooling'];

enum IndexState { saved, incomplete, missing }

class IndexResult {
  final IndexState state;
  final String note;
  final ClassificationRecord<ProjectLabels>? record;
  final Map<String, dynamic>? saved;
  final Map<String, dynamic>? local;
  final String? labelText;
  final String? recordId;
  const IndexResult(
    this.state,
    this.note, {
    this.record,
    this.saved,
    this.local,
    this.labelText,
    this.recordId,
  });

  String get labels =>
      labelText ??
      record?.result.value?.labels.map((l) => l.value).join(', ') ??
      record?.result.outcome.name ??
      '—';

  String details(String kind) {
    final out = StringBuffer('$kind: ${state.name}\n$labels\n$note\n');
    if (record case final value?) {
      out.writeln('Explanation: ${value.result.explanation}');
      for (final label in value.result.value?.labels ?? <ProjectLabel>[]) {
        out.writeln('${label.value}: ${label.evidence.join(', ')}');
      }
      out.writeln('Evidence: ${value.result.evidence.join(', ')}');
      for (final gap in value.coverage.gaps) {
        out.writeln('Gap: $gap');
      }
      out.writeln('Record: ${value.id}');
    }
    const encoder = JsonEncoder.withIndent('  ');
    for (final entry in {'Merged': saved, 'Local': local}.entries) {
      if (entry.value == null) continue;
      out.writeln('${entry.key} classifier and source:');
      out.writeln(encoder.convert(entry.value!['provenance']));
      out.writeln('Request records: ${entry.value!['request_records']}');
    }
    return out.toString();
  }
}

class IndexDirectory {
  final String path;
  final List<String> children;
  final Map<String, IndexResult> results;
  final bool removed;
  final bool hasChildren;
  bool childrenLoaded = false;
  bool hasMore = false;
  IndexDirectory(
    this.path,
    this.children,
    this.results, {
    this.removed = false,
    this.hasChildren = false,
  });

  String get summary => indexKinds
      .map((kind) {
        final result = results[kind]!;
        return '$kind: ${result.labels} [${result.state.name}]';
      })
      .join(' · ');

  String get details => [
    path,
    if (removed) 'Directory is no longer in the indexed repository tree.',
    for (final kind in indexKinds)
      '$kind: ${results[kind]!.labels} [${results[kind]!.state.name}]',
    for (final kind in indexKinds) results[kind]!.details(kind),
  ].join('\n\n');
}

/// Caches only the branches and details the user has opened. The store supplies
/// indexed pages; opening this view never invokes a repository source.
class IndexView {
  final Map<String, IndexDirectory> directories;
  final String? warning;
  final Future<List<IndexDirectory>> Function(String, int, int)? _children;
  final Future<IndexDirectory> Function(String)? _details;
  final Future<void> Function()? _close;
  bool _closed = false;
  IndexView(
    this.directories, {
    this.warning,
    Future<List<IndexDirectory>> Function(String, int, int)? children,
    Future<IndexDirectory> Function(String)? details,
    Future<void> Function()? close,
  }) : _children = children,
       _details = details,
       _close = close;

  Future<void> loadChildren(String path) async {
    if (_closed) throw StateError('Index view is closed');
    final parent = directories[path]!;
    if (_children == null || parent.childrenLoaded && !parent.hasMore) return;
    const page = 100;
    final rows = await _children(path, parent.children.length, page + 1);
    if (_closed) return;
    parent.hasMore = rows.length > page;
    for (final row in rows.take(page)) {
      directories[row.path] = row;
      parent.children.add(row.path);
    }
    parent.childrenLoaded = true;
  }

  Future<IndexDirectory> loadDetails(String path) async {
    if (_closed) throw StateError('Index view is closed');
    return _details == null ? directories[path]! : await _details(path);
  }

  /// Headless output deliberately walks every saved node, but still reads only
  /// small label rows, never evidence payloads or the project filesystem.
  Future<String> readText() async {
    final lines = <String>[
      'Saved index (freshness not checked)',
      if (warning != null) warning!,
    ];
    Future<void> visit(String path) async {
      final node = directories[path]!;
      lines.add('$path: ${node.summary}');
      do {
        await loadChildren(path);
      } while (node.hasMore);
      for (final child in node.children) {
        await visit(child);
      }
    }

    await visit('.');
    return lines.join('\n');
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _close?.call();
  }
}

IndexDirectory _directory(Map<String, dynamic> row) {
  final entries = (row['results'] as List).cast<Map<String, dynamic>>();
  final results = <String, IndexResult>{};
  for (final kind in indexKinds) {
    final matching = entries.where((entry) => entry['kind'] == kind);
    final merged = matching
        .where((entry) => entry['stage'] == 'merged')
        .firstOrNull;
    final saved =
        merged ??
        matching.where((entry) => entry['stage'] == 'local').firstOrNull;
    final coverage = saved?['coverage'] == null
        ? null
        : jsonDecode(saved!['coverage'] as String) as Map;
    final complete = merged != null && coverage?['complete'] == true;
    final labels = saved == null
        ? <String>[]
        : (jsonDecode(saved['labels'] as String) as List).cast<String>();
    results[kind] = IndexResult(
      saved == null
          ? IndexState.missing
          : complete
          ? IndexState.saved
          : IndexState.incomplete,
      saved == null
          ? 'No saved result.'
          : complete
          ? 'Saved classification; repository freshness has not been checked.'
          : merged == null
          ? 'Local result saved; directory merge is missing.'
          : 'Saved result has incomplete input coverage.',
      labelText: saved == null
          ? '—'
          : labels.isEmpty
          ? saved['outcome'] as String? ?? 'unknown'
          : labels.join(', '),
      recordId: saved?['record'] as String?,
    );
  }
  return IndexDirectory(
    row['path'] as String,
    [],
    results,
    hasChildren: row['has_children'] == true,
  );
}

Future<IndexView> readIndex({required SqliteClassificationStore store}) async {
  final root = await store.node('.');
  final rootNode = _directory(
    root ?? {'path': '.', 'has_children': false, 'results': []},
  );
  final view = IndexView(
    {'.': rootNode},
    warning: root == null ? 'No saved index. Run /index to build it.' : null,
    children: (path, offset, limit) async => [
      for (final row in await store.children(
        path,
        offset: offset,
        limit: limit,
      ))
        _directory(row),
    ],
    details: (path) async {
      final row = await store.node(path);
      final node = _directory(
        row ?? {'path': path, 'has_children': false, 'results': []},
      );
      final raw = await store.details(path);
      for (final kind in indexKinds) {
        final summary = node.results[kind]!;
        final merged = raw['task:$path::$kind'] as Map<String, dynamic>?;
        final local = raw['task:$path::$kind::local'] as Map<String, dynamic>?;
        final value = merged ?? local;
        if (value == null) continue;
        final record = ClassificationRecord(
          summary.recordId!,
          ClassificationResult.fromJson(value['result'], projectLabelsContract),
          InputCoverage.fromJson(value['coverage']),
          projectLabelsContract,
        );
        node.results[kind] = IndexResult(
          summary.state,
          summary.note,
          record: record,
          saved: merged,
          local: local,
        );
      }
      return node;
    },
    close: store.close,
  );
  await view.loadChildren('.');
  return view;
}
