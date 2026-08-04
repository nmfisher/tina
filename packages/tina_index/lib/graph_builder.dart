import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:path/path.dart' as p;

import 'edge.dart';
import 'extractor.dart';
import 'graph.dart';
import 'symbol.dart';
import 'symbol_table.dart';

class GraphBuilder {
  static CodeGraph build(SymbolTable symbols, String repoRoot) {
    final edges = <Edge>[];

    // Group class/mixin symbols by file for batch processing.
    final byFile = <String, List<Symbol>>{};
    for (final s in symbols.all) {
      if (s.kind == SymbolKind.class_ || s.kind == SymbolKind.mixin) {
        byFile.putIfAbsent(s.filePath, () => []).add(s);
      }
    }

    for (final entry in byFile.entries) {
      final filePath = entry.key;
      final content = File(filePath).readAsStringSync();
      final result = parseString(
        content: content,
        featureSet: FeatureSet.latestLanguageVersion(),
        throwIfDiagnostics: false,
      );
      final visitor = _StructuralEdgeVisitor(filePath, symbols, repoRoot);
      result.unit.accept(visitor);
      edges.addAll(visitor.edges);
    }

    return CodeGraph(symbols: symbols, edges: edges);
  }

  static void addImportEdges(CodeGraph graph, String repoRoot) {
    final projectName = _readProjectName(repoRoot);
    final files = <String>{};
    for (final s in graph.symbols.all) {
      files.add(s.filePath);
    }

    for (final filePath in files) {
      final directives = SymbolExtractor.parseDirectivesFromFile(filePath);
      final sourceRelPath = p.relative(filePath, from: repoRoot);

      for (final d in directives) {
        final resolved =
            _resolveImportUri(d.uri, filePath, repoRoot, projectName);
        if (resolved == null) continue;

        final targetRelPath = p.relative(resolved, from: repoRoot);
        if (!files.any((f) => p.relative(f, from: repoRoot) == targetRelPath)) {
          continue;
        }

        final edgeKind = d.kind == DirectiveKind.import
            ? EdgeKind.imports
            : d.kind == DirectiveKind.export
                ? EdgeKind.exports
                : EdgeKind.imports; // part directives treated as imports

        graph.addEdge(Edge(
          fromId: sourceRelPath,
          toId: targetRelPath,
          kind: edgeKind,
        ));
      }
    }
  }

  static String? _resolveImportUri(
      String uri, String sourceFilePath, String repoRoot, String projectName) {
    if (uri.startsWith('dart:')) return null;
    if (uri.startsWith('package:')) {
      final withoutScheme = uri.substring('package:'.length);
      final slashIdx = withoutScheme.indexOf('/');
      if (slashIdx < 0) return null;
      final packageName = withoutScheme.substring(0, slashIdx);
      if (packageName != projectName) return null;
      final rest = withoutScheme.substring(slashIdx + 1);
      return p.normalize(p.join(repoRoot, 'lib', rest));
    }
    return p.normalize(p.join(p.dirname(sourceFilePath), uri));
  }

  static String _readProjectName(String repoRoot) {
    final pubspec = File(p.join(repoRoot, 'pubspec.yaml'));
    if (!pubspec.existsSync()) return '';
    final content = pubspec.readAsStringSync();
    final match =
        RegExp(r'^name:\s*(\S+)', multiLine: true).firstMatch(content);
    return match?.group(1) ?? '';
  }
}

class _StructuralEdgeVisitor extends RecursiveAstVisitor<void> {
  final String _filePath;
  final SymbolTable _symbols;
  final String _repoRoot;
  final List<Edge> edges = [];

  _StructuralEdgeVisitor(this._filePath, this._symbols, this._repoRoot);

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final name = node.namePart.typeName.lexeme;
    if (name.startsWith('_')) return;
    final fromId = _qualifiedId(name);
    if (fromId == null) return;

    if (node.extendsClause != null) {
      _resolveAndAdd(fromId, node.extendsClause!.superclass, EdgeKind.extends_);
    }
    if (node.implementsClause != null) {
      for (final type in node.implementsClause!.interfaces) {
        _resolveAndAdd(fromId, type, EdgeKind.implements_);
      }
    }
    if (node.withClause != null) {
      for (final type in node.withClause!.mixinTypes) {
        _resolveAndAdd(fromId, type, EdgeKind.mixesIn);
      }
    }
    super.visitClassDeclaration(node);
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    final name = node.name.lexeme;
    if (name.startsWith('_')) return;
    final fromId = _qualifiedId(name);
    if (fromId == null) return;

    if (node.implementsClause != null) {
      for (final type in node.implementsClause!.interfaces) {
        _resolveAndAdd(fromId, type, EdgeKind.implements_);
      }
    }
    if (node.onClause != null) {
      for (final type in node.onClause!.superclassConstraints) {
        _resolveAndAdd(fromId, type, EdgeKind.extends_);
      }
    }
    super.visitMixinDeclaration(node);
  }

  String? _qualifiedId(String localName) {
    final matches = _symbols.lookupByName(localName).where(
        (s) => s.filePath == _filePath);
    if (matches.isEmpty) return null;
    return _computeQualifiedName(matches.first, _repoRoot);
  }

  void _resolveAndAdd(String fromId, NamedType type, EdgeKind kind) {
    final targetName = type.name.lexeme;
    final matches = _symbols.lookupByName(targetName);
    if (matches.isEmpty) return;

    String? toId;
    if (matches.length == 1) {
      toId = _computeQualifiedName(matches.first, _repoRoot);
    } else {
      // Disambiguate using import directives.
      toId = _disambiguate(targetName, matches);
    }

    if (toId != null) {
      edges.add(Edge(fromId: fromId, toId: toId, kind: kind));
    }
  }

  String? _disambiguate(String name, List<Symbol> candidates) {
    // Simple heuristic: prefer candidates from files imported by the source.
    // For now, just pick the first match (most codebases don't have collisions).
    return _computeQualifiedName(candidates.first, _repoRoot);
  }

  static String _computeQualifiedName(Symbol s, String repoRoot) {
    final relPath = p.relative(s.filePath, from: repoRoot);
    final withoutExt = relPath.endsWith('.dart')
        ? relPath.substring(0, relPath.length - 5)
        : relPath;
    if (s.parentName != null) {
      return '$withoutExt.${s.parentName}.${s.name}';
    }
    return '$withoutExt.${s.name}';
  }
}
