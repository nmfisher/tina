import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import 'package:tina_index/extractor.dart';
import 'package:tina_index/symbol.dart';

String get repoRoot =>
    p.normalize(p.join(p.dirname(p.fromUri(Platform.script.path)), '..', '..'));

void main() {
  group('SymbolExtractor.parseString', () {
    test('extracts class with methods', () {
      final symbols = SymbolExtractor.parseString('test.dart', '''
abstract class Agent {
  void run() {}
  void compact() {}
}
''');
      final agent = symbols.firstWhere((s) => s.name == 'Agent');
      expect(agent.kind, SymbolKind.class_);
      expect(agent.isAbstract, isTrue);
      expect(agent.parentName, isNull);

      final methods =
          symbols.where((s) => s.kind == SymbolKind.method).toList();
      expect(methods, hasLength(2));
      expect(methods.map((s) => s.name), containsAll(['run', 'compact']));
      for (final m in methods) {
        expect(m.parentName, 'Agent');
      }
    });

    test('extracts mixin', () {
      final symbols = SymbolExtractor.parseString('test.dart', '''
mixin Loggable {
  void log(String msg) {}
}
''');
      final loggable = symbols.firstWhere((s) => s.name == 'Loggable');
      expect(loggable.kind, SymbolKind.mixin);
      expect(loggable.isAbstract, isFalse);
    });

    test('extracts enum', () {
      final symbols = SymbolExtractor.parseString('test.dart', '''
enum Color { red, green, blue }
''');
      final color = symbols.firstWhere((s) => s.name == 'Color');
      expect(color.kind, SymbolKind.enum_);
    });

    test('extracts named extension', () {
      final symbols = SymbolExtractor.parseString('test.dart', '''
extension StringX on String {
  String get doubled => this + this;
}
''');
      final ext = symbols.firstWhere((s) => s.name == 'StringX');
      expect(ext.kind, SymbolKind.extension);
    });

    test('skips unnamed extensions', () {
      final symbols = SymbolExtractor.parseString('test.dart', '''
extension on String {
  String doubled => this + this;
}
''');
      expect(symbols.where((s) => s.kind == SymbolKind.extension), isEmpty);
    });

    test('extracts top-level functions', () {
      final symbols = SymbolExtractor.parseString('test.dart', '''
void main() {}
String greet(String name) => 'Hello, \$name!';
''');
      final functions =
          symbols.where((s) => s.kind == SymbolKind.function).toList();
      expect(functions, hasLength(2));
      expect(functions.map((s) => s.name), containsAll(['main', 'greet']));
    });

    test('extracts fields', () {
      final symbols = SymbolExtractor.parseString('test.dart', '''
class Config {
  final String name;
  int count = 0;
}
''');
      final fields =
          symbols.where((s) => s.kind == SymbolKind.field).toList();
      expect(fields, hasLength(2));
      expect(fields.map((s) => s.name), containsAll(['name', 'count']));
      for (final f in fields) {
        expect(f.parentName, 'Config');
      }
    });

    test('skips private declarations', () {
      final symbols = SymbolExtractor.parseString('test.dart', '''
class Foo {
  void _hidden() {}
  String _secret = '';
}
void _helper() {}
''');
      expect(symbols.map((s) => s.name), isNot(contains('_hidden')));
      expect(symbols.map((s) => s.name), isNot(contains('_secret')));
      expect(symbols.map((s) => s.name), isNot(contains('_helper')));
    });

    test('handles empty file', () {
      final symbols = SymbolExtractor.parseString('test.dart', '');
      expect(symbols, isEmpty);
    });

    test('handles syntax errors gracefully', () {
      // Malformed input — extractor should not throw.
      final symbols = SymbolExtractor.parseString('test.dart', 'class { }');
      // May produce partial results; just verify it doesn't crash.
      expect(symbols, isA<List<Symbol>>());
    });

    test('line ranges are correct', () {
      final symbols = SymbolExtractor.parseString('test.dart', 'class Foo {\n'
          '  void bar() {}\n'
          '}\n');
      final foo = symbols.firstWhere((s) => s.name == 'Foo');
      expect(foo.lineStart, 1);
      expect(foo.lineEnd, 3);

      final bar = symbols.firstWhere((s) => s.name == 'bar');
      expect(bar.lineStart, 2);
      expect(bar.lineEnd, 2);
    });
  });

  group('SymbolExtractor.parseFile', () {
    test('parses agent.dart from tina repo', () {
      final path = p.join(repoRoot, 'lib', 'agent', 'agent.dart');
      if (!File(path).existsSync()) return; // skip if running outside repo

      final symbols = SymbolExtractor.parseFile(path);
      final agent = symbols.where((s) => s.name == 'Agent').toList();
      expect(agent, hasLength(1));
      expect(agent.first.kind, SymbolKind.class_);

      final agentMethods = symbols
          .where((s) => s.parentName == 'Agent' && s.kind == SymbolKind.method)
          .map((s) => s.name)
          .toList();
      expect(agentMethods, containsAll(['run', 'compact']));
    });
  });
}
