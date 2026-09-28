/// AST-derived dependency graph for Dart codebases.
///
/// - [Symbol] / [SymbolKind]: node model
/// - [Edge] / [EdgeKind]: typed edges (extends, implements, imports, etc.)
/// - [CodeGraph]: graph container with bidirectional edge lookup
/// - [SymbolTable]: qualified-name-indexed symbol lookup
/// - [SymbolExtractor]: parse Dart files into symbols
/// - [GraphBuilder]: extract structural and import edges
/// - [DartFileWalker]: discover .dart files in a repo
/// - [GraphStore]: serialize/deserialize graph to disk
/// - [GraphTraversal]: expand seed symbols through the graph
/// - [seedQuery]: keyword-based symbol matching
library;

export 'edge.dart';
export 'extractor.dart';
export 'fuzzy.dart';
export 'graph.dart';
export 'hasher.dart';
export 'graph_builder.dart';
export 'seeding.dart';
export 'store.dart';
export 'symbol.dart';
export 'symbol_table.dart';
export 'traversal.dart';
export 'walker.dart';
