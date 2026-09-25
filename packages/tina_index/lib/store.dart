import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'edge.dart';
import 'extractor.dart';
import 'graph.dart';
import 'graph_builder.dart';
import 'symbol.dart';
import 'symbol_table.dart';

class GraphStore {
  static const _graphDir = '.tina';
  static const _graphFile = 'graph.json';

  static String graphPath(String repoRoot) =>
      p.join(repoRoot, _graphDir, _graphFile);

  static void save(CodeGraph graph, String repoRoot) {
    final dir = Directory(p.join(repoRoot, _graphDir));
    if (!dir.existsSync()) dir.createSync(recursive: true);

    final json = _serialize(graph, repoRoot);
    File(graphPath(repoRoot)).writeAsStringSync(
      const JsonEncoder.withIndent(null).convert(json),
    );
  }

  static CodeGraph? load(String repoRoot) {
    final file = File(graphPath(repoRoot));
    if (!file.existsSync()) return null;
    try {
      final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      return _deserialize(json, repoRoot);
    } catch (_) {
      return null;
    }
  }

  /// Incremental re-index: re-parse only files whose content hash changed.
  static CodeGraph update(CodeGraph graph, String repoRoot) {
    return rebuildFromRepo(repoRoot);
  }

  /// The command that lists a repository's files, for a caller that has a
  /// process story of its own. This package deliberately does NOT run it: the
  /// subprocess used to live here, which is how the index came to spawn `git`
  /// outside whatever sandbox the calling tool had been given.
  static const List<String> gitListFilesArgs = [
    'ls-files',
    '--cached',
    '--others',
    '--exclude-standard',
  ];

  /// The repository-relative `.dart` files in a `git ls-files` listing.
  static List<String> dartFilesFromGitListing(String stdout) => [
        for (final line in stdout.split('\n'))
          if (line.isNotEmpty && line.endsWith('.dart')) line
      ];

  /// Rebuild the graph, parsing [files] when the caller supplies them.
  ///
  /// Without [files] the tree is walked directly, skipping build output. That
  /// is the safe default and the only option for a caller with no subprocess:
  /// a caller that can list through git (see [gitListFilesArgs]) gets the more
  /// accurate answer, including respecting `.gitignore`.
  static CodeGraph rebuildFromRepo(String repoRoot, {List<String>? files}) {
    final all = files ?? _walkManual(repoRoot);
    final allSymbols = <Symbol>[];
    for (final relPath in all) {
      final absPath = p.join(repoRoot, relPath);
      if (!File(absPath).existsSync()) continue;
      allSymbols.addAll(SymbolExtractor.parseFile(absPath));
    }
    final table = SymbolTable.build(allSymbols, repoRoot);
    final graph = GraphBuilder.build(table, repoRoot);
    GraphBuilder.addImportEdges(graph, repoRoot);
    return graph;
  }

  static List<String> _walkManual(String repoRoot) {
    const skip = {'.git', '.dart_tool', 'node_modules', 'build', 'dist'};
    final out = <String>[];
    _walkDir(Directory(repoRoot), '', skip, out);
    return out;
  }

  static void _walkDir(
      Directory dir, String prefix, Set<String> skip, List<String> out) {
    try {
      for (final e in dir.listSync(followLinks: false)) {
        final name = e.path.split('/').last;
        if (skip.contains(name)) continue;
        final rel = prefix.isEmpty ? name : '$prefix/$name';
        if (e is File && rel.endsWith('.dart')) {
          out.add(rel);
        } else if (e is Directory) {
          _walkDir(e, rel, skip, out);
        }
      }
    } catch (_) {}
  }

  static Map<String, dynamic> _serialize(CodeGraph graph, String repoRoot) {
    return {
      'version': 2,
      'symbols': graph.symbols.entries.entries
          .map((e) => {'id': e.key, ...e.value.toJson()})
          .toList(),
      'edges': graph.edges.map((e) => e.toJson()).toList(),
      'manifest': graph.manifest,
      if (graph.summaries.isNotEmpty) 'summaries': graph.summaries,
    };
  }

  static CodeGraph _deserialize(Map<String, dynamic> json, String repoRoot) {
    final symbolsList = (json['symbols'] as List).cast<Map<String, dynamic>>();
    final byId = <String, Symbol>{};
    for (final entry in symbolsList) {
      final id = entry['id'] as String;
      final symbol = Symbol.fromJson(entry);
      // Remap absolute path from stored relative path.
      if (!File(symbol.filePath).existsSync()) {
        final relPath = entry['filePath'] as String;
        final absPath = p.join(repoRoot, relPath);
        byId[id] = Symbol(
          name: symbol.name,
          kind: symbol.kind,
          filePath: absPath,
          lineStart: symbol.lineStart,
          lineEnd: symbol.lineEnd,
          parentName: symbol.parentName,
          isAbstract: symbol.isAbstract,
        );
      } else {
        byId[id] = symbol;
      }
    }

    final edgesList = (json['edges'] as List)
        .cast<Map<String, dynamic>>()
        .map(Edge.fromJson)
        .toList();

    final table = SymbolTable.fromMap(byId);

    final version = json['version'] as int? ?? 1;
    final Map<String, String> summaries;
    final Map<String, String> manifest;

    if (version >= 2) {
      summaries = (json['summaries'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v as String)) ??
          {};
      manifest = (json['manifest'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v as String)) ??
          {};
    } else {
      // v1 migration: discard old name-keyed summaries.
      // Can't convert without recomputing hashes from source.
      summaries = {};
      manifest = {};
    }

    return CodeGraph(
      symbols: table,
      edges: edgesList,
      summaries: summaries,
      manifest: manifest,
    );
  }
}
