import 'dart:io';

import 'package:path/path.dart' as p;

import 'extractor.dart';
import 'symbol.dart';
import 'walker.dart';

class SymbolTable {
  final Map<String, Symbol> _byId;

  SymbolTable._(this._byId);

  /// Construct from a pre-built qualified-name → symbol map.
  factory SymbolTable.fromMap(Map<String, Symbol> byId) => SymbolTable._(byId);

  Symbol? operator [](String qualifiedName) => _byId[qualifiedName];

  Iterable<Symbol> get all => _byId.values;

  int get length => _byId.length;

  Iterable<String> get qualifiedNames => _byId.keys;

  /// The underlying qualified-name → symbol mapping.
  Map<String, Symbol> get entries => Map.unmodifiable(_byId);

  Iterable<Symbol> byKind(SymbolKind kind) =>
      _byId.values.where((s) => s.kind == kind);

  List<Symbol> childrenOf(String qualifiedName) {
    final parent = _byId[qualifiedName];
    if (parent == null) return const [];
    return _byId.values
        .where((s) => s.filePath == parent.filePath && s.parentName == parent.name)
        .toList();
  }

  List<Symbol> lookupByName(String name) {
    return _byId.values.where((s) => s.name == name).toList();
  }

  static Future<SymbolTable> buildFromRepo(String repoRoot) async {
    final walker = DartFileWalker(repoRoot: repoRoot);
    final files = await walker.walk();
    final allSymbols = <Symbol>[];
    for (final relPath in files) {
      final absPath = p.join(repoRoot, relPath);
      if (!File(absPath).existsSync()) continue;
      final symbols = SymbolExtractor.parseFile(absPath);
      allSymbols.addAll(symbols);
    }
    return build(allSymbols, repoRoot);
  }

  static SymbolTable build(List<Symbol> symbols, String repoRoot) {
    final byId = <String, Symbol>{};
    for (final s in symbols) {
      final id = _qualifiedName(s, repoRoot);
      byId[id] = s;
    }
    return SymbolTable._(byId);
  }

  static String _qualifiedName(Symbol s, String repoRoot) {
    final relPath = p.relative(s.filePath, from: repoRoot);
    // Strip the .dart extension: "lib/agent/agent.dart" → "lib/agent/agent"
    final withoutExt = relPath.endsWith('.dart')
        ? relPath.substring(0, relPath.length - 5)
        : relPath;
    if (s.parentName != null) {
      return '$withoutExt.${s.parentName}.${s.name}';
    }
    return '$withoutExt.${s.name}';
  }
}
