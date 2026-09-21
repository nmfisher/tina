import 'package:test/test.dart';

import 'package:tina_index/symbol.dart';
import 'package:tina_index/symbol_table.dart';

import 'helpers/index_project.dart';

void main() {
  group('SymbolTable.build', () {
    test('computes qualified names', () {
      final symbols = [
        Symbol(
          name: 'Agent',
          kind: SymbolKind.class_,
          filePath: '/root/lib/agent/agent.dart',
          lineStart: 1,
          lineEnd: 100,
        ),
        Symbol(
          name: 'run',
          kind: SymbolKind.method,
          filePath: '/root/lib/agent/agent.dart',
          lineStart: 10,
          lineEnd: 20,
          parentName: 'Agent',
        ),
      ];
      final table = SymbolTable.build(symbols, '/root');
      expect(table['lib/agent/agent.Agent'], isNotNull);
      expect(table['lib/agent/agent.Agent.run'], isNotNull);
    });

    test('childrenOf returns child symbols', () {
      final symbols = [
        Symbol(
          name: 'Agent',
          kind: SymbolKind.class_,
          filePath: '/root/lib/agent/agent.dart',
          lineStart: 1,
          lineEnd: 100,
        ),
        Symbol(
          name: 'run',
          kind: SymbolKind.method,
          filePath: '/root/lib/agent/agent.dart',
          lineStart: 10,
          lineEnd: 20,
          parentName: 'Agent',
        ),
        Symbol(
          name: 'compact',
          kind: SymbolKind.method,
          filePath: '/root/lib/agent/agent.dart',
          lineStart: 30,
          lineEnd: 40,
          parentName: 'Agent',
        ),
      ];
      final table = SymbolTable.build(symbols, '/root');
      final children = table.childrenOf('lib/agent/agent.Agent');
      expect(children, hasLength(2));
      expect(children.map((s) => s.name), containsAll(['run', 'compact']));
    });

    test('lookupByName finds all matches', () {
      final symbols = [
        Symbol(
          name: 'Agent',
          kind: SymbolKind.class_,
          filePath: '/root/lib/agent/agent.dart',
          lineStart: 1,
          lineEnd: 100,
        ),
        Symbol(
          name: 'Agent',
          kind: SymbolKind.class_,
          filePath: '/root/lib/other/agent.dart',
          lineStart: 1,
          lineEnd: 50,
        ),
      ];
      final table = SymbolTable.build(symbols, '/root');
      expect(table.lookupByName('Agent'), hasLength(2));
    });

    test('empty table', () {
      final table = SymbolTable.build([], '/root');
      expect(table.length, 0);
    });
  });

  group('SymbolTable.buildFromRepo', () {
    test('indexes source files and excludes generated directories', () async {
      final repoRoot = createIndexProject(extraFiles: {
        '.dart_tool/generated.dart': 'class Generated {}',
      }).path;
      final table = await SymbolTable.buildFromRepo(repoRoot);
      expect(table.length, greaterThan(0));

      expect(table.lookupByName('Controller'), hasLength(1));
      expect(table.lookupByName('Base'), hasLength(1));
      expect(table.lookupByName('First'), hasLength(1));
      expect(table.lookupByName('Second'), hasLength(1));
      expect(table.lookupByName('Generated'), isEmpty);

      // No symbols from .dart_tool
      expect(table.qualifiedNames, isNot(anyElement(contains('.dart_tool'))));

      // Children of the fixture controller
      final controllerId = table.qualifiedNames.firstWhere(
        (q) => q == 'lib/controller.Controller',
      );
      final children = table.childrenOf(controllerId);
      expect(children.map((s) => s.name), contains('run'));
    });
  });
}
