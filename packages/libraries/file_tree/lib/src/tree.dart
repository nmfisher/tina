import 'dart:convert';
import 'package:crypto/crypto.dart';

/// Paths in a snapshot are relative, use '/', and never contain traversal.
bool validPath(String path) =>
    path.isNotEmpty &&
    !path.contains('\\') &&
    !path.contains(':') &&
    !path.contains('\u0000') &&
    path
        .split('/')
        .every((part) => part.isNotEmpty && part != '.' && part != '..');

String parent(String path) {
  final slash = path.lastIndexOf('/');
  return slash < 0 ? '.' : path.substring(0, slash);
}

String _hash(Object value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();

class Entry {
  final String path;
  final bool directory;
  final List<String> children;
  final String names;

  /// Null when the scan did not read contents. Never substitutes metadata for bytes.
  final String? content;
  Entry._(
    this.path,
    this.directory,
    Iterable<String> children,
    this.names,
    this.content,
  ) : children = List.unmodifiable(children);
}

class Snapshot {
  final Map<String, Entry> entries;
  Snapshot._(Map<String, Entry> entries) : entries = Map.unmodifiable(entries);
  Entry get root => entries['.']!;
}

enum ChangeKind { added, removed, changed }

class Change {
  final String path;
  final ChangeKind kind;
  Change(this.path, this.kind);
}

/// Build a tree from a complete inventory supplied by the caller. Git, ignores,
/// permissions and cancellation belong to that caller. No partial scan is returned.
/// Omit [read] for a names-only snapshot. Reads can enforce their own byte budget.
Future<Snapshot> scan({
  required Future<Iterable<String>> Function() list,
  Future<List<int>> Function(String path)? read,
  bool Function(String path)? include,
  int maxFiles = 100000,
  int maxDepth = 128,
}) async {
  if (maxFiles < 1 || maxDepth < 1) throw ArgumentError('Invalid scan limits');
  final files = <String>{};
  for (final path in await list()) {
    if (!validPath(path)) throw FormatException('Invalid file path: $path');
    if (include != null && !include(path)) continue;
    if (path.split('/').length > maxDepth)
      throw StateError('Tree depth limit reached');
    files.add(path);
    if (files.length > maxFiles) throw StateError('File limit reached');
  }
  final children = <String, Set<String>>{'.': {}};
  final entries = <String, Entry>{};
  for (final path in files.toList()..sort()) {
    entries[path] = Entry._(
      path,
      false,
      [],
      _hash(path),
      read == null ? null : sha256.convert(await read(path)).toString(),
    );
    var child = path;
    while (child != '.') {
      final dir = parent(child);
      (children[dir] ??= {}).add(child);
      child = dir;
    }
  }
  if (children.keys.any(files.contains))
    throw FormatException('File/directory conflict');
  final dirs = children.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  for (final dir in dirs) {
    final paths = children[dir]!.toList()..sort();
    entries[dir] = Entry._(
      dir,
      true,
      paths,
      _hash([
        for (final p in paths) [p, entries[p]!.names],
      ]),
      read == null
          ? null
          : _hash([
              for (final p in paths) [p, entries[p]!.content],
            ]),
    );
  }
  return Snapshot._(entries);
}

/// Includes affected ancestors. Content comparisons require two content scans.
List<Change> diff(Snapshot before, Snapshot after, {bool contents = false}) {
  if (contents && (before.root.content == null || after.root.content == null)) {
    throw ArgumentError('Content diff requires content snapshots');
  }
  final paths = {...before.entries.keys, ...after.entries.keys}.toList()
    ..sort();
  return [
    for (final path in paths)
      if (!before.entries.containsKey(path))
        Change(path, ChangeKind.added)
      else if (!after.entries.containsKey(path))
        Change(path, ChangeKind.removed)
      else if (before.entries[path]!.directory !=
              after.entries[path]!.directory ||
          before.entries[path]!.names != after.entries[path]!.names ||
          (contents &&
              before.entries[path]!.content != after.entries[path]!.content))
        Change(path, ChangeKind.changed),
  ];
}
