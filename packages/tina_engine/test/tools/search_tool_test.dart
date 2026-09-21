import 'dart:io';

import 'package:test/test.dart';

import 'package:tina_engine/src/tools/process_runner.dart';
import 'package:tina_engine/tina_engine.dart';
import 'package:tina_index/tina_index.dart';

import '../helpers/memory_process_runner.dart';

String get repoRoot => Directory.current.path;

void main() {
  group('SearchTool', () {
    late SearchTool tool;

    setUp(() {
      // A real runner, so the listing is what git reports — the same input
      // these assertions were written against. The runner path itself is
      // covered by the dedicated test below.
      tool = SearchTool(
        repoRoot: repoRoot,
        processRunner: const IoProcessRunner(),
      );
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

    test('asks for the file listing through the runner it was given', () async {
      final dir = Directory.systemTemp.createTempSync('search-runner-');
      addTearDown(() => dir.deleteSync(recursive: true));
      final runner = MemoryProcessRunner(
          (exe, args) => MemoryRunningProcess(stdoutChunks: <String>['a.dart\n']));
      final scoped = SearchTool(repoRoot: dir.path, processRunner: runner);

      await scoped.execute({'symbol': 'anything'});

      // One spawn, and it is the listing — handed to a runner the composition
      // chose, which is how the subprocess ends up sandboxed when the sandbox
      // is on. It used to be a `Process.runSync` inside tina_index.
      expect(runner.runs, hasLength(1));
      expect(runner.runs.single.executable, 'git');
      expect(runner.runs.single.arguments, GraphStore.gitListFilesArgs);
    });

  });
}