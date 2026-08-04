import 'dart:io';

import 'package:test/test.dart';

import 'package:tina_engine/tina_engine.dart';

String get repoRoot => Directory.current.path;

void main() {
  group('SearchTool', () {
    late SearchTool tool;

    setUp(() {
      tool = SearchTool(repoRoot: repoRoot);
    });

    test('schema has correct name and required symbol param', () {
      expect(tool.schema.name, 'search');
      final props =
          tool.schema.inputSchema['properties'] as Map<String, dynamic>;
      expect(props, contains('symbol'));
      final required =
          tool.schema.inputSchema['required'] as List;
      expect(required, contains('symbol'));
    });

    test('search for LlmProvider returns both providers', () async {
      final result = await tool.execute({'symbol': 'LlmProvider'});
      expect(result.isError, isFalse);
      expect(result.content, contains('LlmProvider'));
      expect(result.content, contains('AnthropicProvider'));
      expect(result.content, contains('OpenAiProvider'));
    });

    test('search for Agent returns methods', () async {
      final result = await tool.execute({'symbol': 'Agent'});
      expect(result.isError, isFalse);
      expect(result.content, contains('Agent'));
    });

    test('search with qualified name works', () async {
      final result =
          await tool.execute({'symbol': 'lib/llm/provider.LlmProvider'});
      expect(result.isError, isFalse);
      expect(result.content, contains('LlmProvider'));
    });

    test('search for nonexistent symbol returns not found', () async {
      final result = await tool.execute({'symbol': 'NonExistent'});
      expect(result.isError, isFalse);
      expect(result.content, contains('No symbol matching'));
    });

    test('search with empty symbol returns error', () async {
      final result = await tool.execute({'symbol': ''});
      expect(result.isError, isTrue);
    });

    test('search with missing symbol returns error', () async {
      final result = await tool.execute({});
      expect(result.isError, isTrue);
    });
  });
}
