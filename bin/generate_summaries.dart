import 'dart:io';

import 'package:args/args.dart';
import 'package:tina_index/tina_index.dart';
import 'package:tina_engine/tina_engine.dart';

Future<void> main(List<String> argv) async {
  final parser = ArgParser()
    ..addOption('base-url',
        defaultsTo: Platform.environment['OPENAI_BASE_URL'] ??
            'http://localhost:8080')
    ..addOption('model',
        defaultsTo:
            Platform.environment['OPENAI_MODEL'] ?? 'qwen3.5:0.8b')
    ..addOption('api-key',
        defaultsTo: Platform.environment['OPENAI_API_KEY'] ?? 'unused')
    ..addFlag('dry-run',
        abbr: 'n',
        negatable: false,
        help: 'Count LLM calls without executing them')
    ..addFlag('help', abbr: 'h', negatable: false);

  final args = parser.parse(argv);
  if (args['help'] as bool) {
    print('Generate hierarchical code summaries using a local LLM.\n');
    print('Usage: dart run bin/generate_summaries.dart [options]\n');
    print(parser.usage);
    return;
  }

  final baseUrl = args['base-url'] as String;
  final model = args['model'] as String;
  final apiKey = args['api-key'] as String;
  final dryRun = args['dry-run'] as bool;
  final repoRoot = Directory.current.path;

  print('Building dependency graph...');
  final graph = GraphStore.rebuildFromRepo(repoRoot);
  print('  ${graph.symbols.length} symbols indexed');

  final existingSummaries = graph.summaries.length;
  print('  $existingSummaries existing summaries');

  if (dryRun) {
    final count = SummaryGenerator.countPending(graph, repoRoot);
    print('\nDry run: $count LLM calls needed');
    return;
  }

  print('\nGenerating summaries with $model at $baseUrl...');
  final provider = OpenAiProvider(
    apiKey: apiKey,
    model: model,
    baseUrl: baseUrl,
    maxTokens: 200,
  );

  final generator =
      SummaryGenerator(provider: provider, repoRoot: repoRoot);
  final count = await generator.generateIncremental(graph);

  GraphStore.save(graph, repoRoot);
  print('\nDone. Generated $count new summaries '
      '(${graph.summaries.length} total).');
  print('Saved to .tina/graph.json');

  provider.close();
}
