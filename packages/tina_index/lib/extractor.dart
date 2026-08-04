import 'dart:io';

import 'package:analyzer/dart/analysis/features.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/analysis/utilities.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/source/line_info.dart';

import 'symbol.dart';

enum DirectiveKind { import, export, part_ }

class Directive {
  final DirectiveKind kind;
  final String uri;
  const Directive({required this.kind, required this.uri});
}

class SymbolExtractor {
  static List<Symbol> parseFile(String filePath) {
    final content = File(filePath).readAsStringSync();
    return parseString(filePath, content);
  }

  static List<Symbol> parseString(String filePath, String content) {
    final result = _doParse(content);
    // Don't bail on errors — the AST is still mostly valid. Broken files
    // produce partial results which is better than nothing.
    final visitor = _DeclarationVisitor(filePath, result.lineInfo);
    result.unit.accept(visitor);
    return visitor.symbols;
  }

  static List<Directive> parseDirectivesFromFile(String filePath) {
    final content = File(filePath).readAsStringSync();
    return parseDirectivesFromString(content);
  }

  static List<Directive> parseDirectivesFromString(String content) {
    final result = _doParse(content);
    final directives = <Directive>[];
    for (final d in result.unit.directives) {
      final String? uri;
      final DirectiveKind kind;
      if (d is ImportDirective) {
        uri = d.uri.stringValue;
        kind = DirectiveKind.import;
      } else if (d is ExportDirective) {
        uri = d.uri.stringValue;
        kind = DirectiveKind.export;
      } else if (d is PartDirective) {
        uri = d.uri.stringValue;
        kind = DirectiveKind.part_;
      } else {
        continue;
      }
      if (uri != null && uri.isNotEmpty) {
        directives.add(Directive(kind: kind, uri: uri));
      }
    }
    return directives;
  }
}

ParseStringResult _doParse(String content) {
  return parseString(
    content: content,
    featureSet: FeatureSet.latestLanguageVersion(),
    throwIfDiagnostics: false,
  );
}

class _DeclarationVisitor extends RecursiveAstVisitor<void> {
  final String filePath;
  final LineInfo lineInfo;
  final List<Symbol> symbols = [];
  String? enclosingClass;

  _DeclarationVisitor(this.filePath, this.lineInfo);

  @override
  void visitClassDeclaration(ClassDeclaration node) {
    final name = node.namePart.typeName.lexeme;
    if (_isPrivate(name)) return;
    _addSymbol(name, SymbolKind.class_, node,
        isAbstract: node.abstractKeyword != null);
    _withEnclosing(name, () => super.visitClassDeclaration(node));
  }

  @override
  void visitMixinDeclaration(MixinDeclaration node) {
    final name = node.name.lexeme;
    if (_isPrivate(name)) return;
    _addSymbol(name, SymbolKind.mixin, node);
    _withEnclosing(name, () => super.visitMixinDeclaration(node));
  }

  @override
  void visitEnumDeclaration(EnumDeclaration node) {
    final name = node.namePart.typeName.lexeme;
    if (_isPrivate(name)) return;
    _addSymbol(name, SymbolKind.enum_, node);
  }

  @override
  void visitExtensionDeclaration(ExtensionDeclaration node) {
    final name = node.name;
    if (name == null) return;
    if (_isPrivate(name.lexeme)) return;
    _addSymbol(name.lexeme, SymbolKind.extension, node);
    _withEnclosing(name.lexeme, () => super.visitExtensionDeclaration(node));
  }

  @override
  void visitFunctionDeclaration(FunctionDeclaration node) {
    if (enclosingClass != null) return;
    if (node.parent is FunctionDeclarationStatement) return;
    final name = node.name.lexeme;
    if (_isPrivate(name)) return;
    _addSymbol(name, SymbolKind.function, node);
  }

  @override
  void visitMethodDeclaration(MethodDeclaration node) {
    if (enclosingClass == null) return;
    final name = node.name.lexeme;
    if (_isPrivate(name)) return;
    _addSymbol(name, SymbolKind.method, node, parentName: enclosingClass);
  }

  @override
  void visitFieldDeclaration(FieldDeclaration node) {
    if (enclosingClass == null) return;
    for (final field in node.fields.variables) {
      final name = field.name.lexeme;
      if (_isPrivate(name)) continue;
      _addSymbol(name, SymbolKind.field, node, parentName: enclosingClass);
    }
  }

  void _addSymbol(String name, SymbolKind kind, AstNode node,
      {String? parentName, bool isAbstract = false}) {
    symbols.add(Symbol(
      name: name,
      kind: kind,
      filePath: filePath,
      lineStart: lineInfo.getLocation(node.offset).lineNumber,
      lineEnd: lineInfo.getLocation(node.end - 1).lineNumber,
      parentName: parentName,
      isAbstract: isAbstract,
    ));
  }

  void _withEnclosing(String name, void Function() body) {
    final prev = enclosingClass;
    enclosingClass = name;
    body();
    enclosingClass = prev;
  }

  bool _isPrivate(String name) => name.startsWith('_');
}
