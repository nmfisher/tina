import 'dart:convert';

import 'package:classifier/classification.dart';
import 'package:classifier/judgments.dart';

import 'project_classifiers.dart';

const indexKinds = ['language', 'framework', 'tooling'];

enum IndexState { current, stale, incomplete, missing }

class IndexResult {
  final IndexState state;
  final String note;
  final ClassificationRecord<ProjectLabels>? record;
  final Map<String, dynamic>? saved;
  final Map<String, dynamic>? local;
  const IndexResult(
    this.state,
    this.note, {
    this.record,
    this.saved,
    this.local,
  });

  String get labels =>
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
  IndexDirectory(
    this.path,
    this.children,
    this.results, {
    this.removed = false,
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

class IndexView {
  final Map<String, IndexDirectory> directories;
  final String? warning;
  IndexView(this.directories, {this.warning});

  String get text => [
    'Saved index (input freshness checked locally; no classifier calls)',
    if (warning != null) warning!,
    for (final directory in directories.values)
      '${directory.path}: ${directory.summary}',
  ].join('\n');
}

/// Read one manifest snapshot and validate saved input receipts and merge
/// dependencies using the same source implementations as indexing. No writer,
/// executor, credentials or classifier configuration is needed. "Current"
/// describes saved inputs, not compatibility with a newly configured model.
Future<IndexView> readIndex({
  required ClassificationStore store,
  required TreeSource<TextEvidence> source,
  required JudgmentCancellation cancellation,
}) async {
  void check() {
    if (cancellation.isCancelled) throw StateError('Index view cancelled');
  }

  final manifest = await store.readManifest();
  check();
  final ids = manifest?['schema_version'] == classificationSchemaVersion
      ? Map<String, String>.from(manifest!['records'] as Map)
      : <String, String>{};
  final saved = <String, Map<String, dynamic>>{};
  final records = <String, ClassificationRecord<ProjectLabels>>{};
  final paths = <String>{'.'};
  for (final entry in ids.entries) {
    check();
    if (!entry.key.startsWith('task:')) continue;
    final key = entry.key.substring(5);
    final parts = key.split('::');
    if (parts.length < 2 || !indexKinds.contains(parts[1])) continue;
    final path = parts[0];
    if (path != '.' &&
        (path.startsWith('/') ||
            path.split('/').any((p) => p.isEmpty || p == '.' || p == '..')))
      continue;
    paths.add(path);
    try {
      final json = await store.readRecord(entry.value);
      if (json == null ||
          json['schema_version'] != classificationSchemaVersion ||
          canonicalFingerprint(json) != entry.value)
        continue;
      final record = ClassificationRecord(
        entry.value,
        ClassificationResult.fromJson(json['result'], projectLabelsContract),
        InputCoverage.fromJson(json['coverage']),
        projectLabelsContract,
      );
      saved[key] = json;
      records[key] = record;
    } catch (_) {
      // A damaged checkpoint must not prevent browsing healthy siblings.
    }
  }
  TreeSnapshot? tree;
  String? warning;
  try {
    tree = await source.tree(SourceRequest('.'), cancellation);
    paths.addAll(tree.nodes.keys);
  } catch (e) {
    check();
    warning = 'Could not check repository inputs: $e';
  }
  if (manifest == null) warning = 'No saved index. Run /index to build it.';
  if (manifest != null &&
      manifest['schema_version'] != classificationSchemaVersion) {
    warning = 'Saved index format is unsupported. Run /index to rebuild it.';
  }
  String parent(String path) =>
      path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '.';
  for (final path in paths.toList()) {
    var current = path;
    while (current != '.') {
      current = parent(current);
      paths.add(current);
    }
  }
  final children = {for (final path in paths) path: <String>[]};
  for (final path in paths.where((p) => p != '.')) {
    children[parent(path)]!.add(path);
  }
  for (final list in children.values) {
    list.sort();
  }
  final results = <String, IndexResult>{};
  final observations = <String, bool>{};
  final ordered = paths.toList()..sort((a, b) => b.length.compareTo(a.length));
  for (final path in ordered) {
    final node = tree?.nodes[path];
    for (final kind in indexKinds) {
      check();
      final key = '$path::$kind';
      final json = saved[key];
      final localKey = '$key::local';
      final local = saved[localKey];
      final record = records[key];
      var state = IndexState.current;
      var note = 'Saved inputs and child results match the repository.';
      void mark(IndexState value, String reason) {
        state = value;
        note = reason;
      }

      if (json == null) {
        mark(
          local == null ? IndexState.missing : IndexState.incomplete,
          local == null
              ? 'No readable saved result.'
              : 'Local result saved; directory merge is missing.',
        );
      } else if (tree == null) {
        mark(IndexState.incomplete, 'Input freshness could not be checked.');
      } else if (node == null) {
        mark(IndexState.stale, 'Directory is no longer in the indexed tree.');
      } else {
        try {
          final parts = <Part<ProjectLabels>>[];
          if (node.input != null) {
            final localRecord = records[localKey];
            if (local == null || localRecord == null) {
              mark(IndexState.incomplete, 'Local classification is missing.');
            } else {
              final revision = SourceRevision(
                jsonObject(local['source_revision']),
              );
              final hash = canonicalFingerprint(revision.receipt);
              final current = observations[hash] ??= await source.isCurrent(
                revision,
                cancellation,
              );
              if (!current) mark(IndexState.stale, 'Local input has changed.');
              parts.add(
                Part(localKey, localRecord.result, localRecord.coverage),
              );
            }
          }
          for (final child in node.children) {
            final result = results['$child::$kind']!;
            final childRecord = records['$child::$kind'];
            if (result.state != IndexState.current) {
              mark(
                result.state == IndexState.stale
                    ? IndexState.stale
                    : IndexState.incomplete,
                'Child $child is ${result.state.name}.',
              );
            }
            if (childRecord != null)
              parts.add(Part(child, childRecord.result, childRecord.coverage));
          }
          final partsSource = PartsSource(projectLabelsContract, parts);
          if (state == IndexState.current &&
              !await partsSource.isCurrent(
                SourceRevision(jsonObject(json['source_revision'])),
                cancellation,
              ))
            mark(
              IndexState.stale,
              'Directory membership or child results changed.',
            );
          // Framework candidates depend on the language result as well.
          for (final checkpoint in [
            json,
            if (node.input != null && local != null) local,
          ]) {
            final upstream = jsonObject(
              jsonObject(checkpoint['provenance'])['upstream'],
            );
            for (final dependency in upstream.entries) {
              final dependencyKey = '$path::${dependency.key}';
              if (results[dependencyKey]?.state != IndexState.current ||
                  canonicalFingerprint(dependency.value) !=
                      canonicalFingerprint(
                        records[dependencyKey]?.dependency,
                      )) {
                mark(
                  IndexState.stale,
                  '${dependency.key} prerequisite changed or is incomplete.',
                );
              }
            }
          }
          if (state == IndexState.current && !record!.coverage.complete) {
            mark(IndexState.incomplete, record.coverage.gaps.join(' '));
          }
        } catch (e) {
          check();
          mark(IndexState.incomplete, 'Could not validate saved inputs: $e');
        }
      }
      results[key] = IndexResult(
        state,
        note,
        record: record ?? records[localKey],
        saved: json,
        local: local,
      );
    }
  }
  check();
  if (tree != null &&
      !await source.isTreeCurrent(tree.revision, cancellation)) {
    warning = 'Repository changed while checking. Close and reopen the view.';
    for (final key in results.keys.toList()) {
      final result = results[key]!;
      if (result.state == IndexState.current)
        results[key] = IndexResult(
          IndexState.stale,
          warning,
          record: result.record,
          saved: result.saved,
          local: result.local,
        );
    }
  }
  check();
  final sorted = paths.toList()..sort();
  return IndexView({
    for (final path in sorted)
      path: IndexDirectory(path, children[path]!, {
        for (final kind in indexKinds) kind: results['$path::$kind']!,
      }, removed: tree != null && !tree.nodes.containsKey(path)),
  }, warning: warning);
}
