import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:test/test.dart';

import 'dart:convert';

import 'package:tina_index/graph.dart';
import 'package:tina_index/store.dart';

String get repoRoot => p.normalize(p.join(Directory.current.path, '..', '..'));

void main() {
  group('GraphStore', () {
    late String tempDir;

    setUp(() {
      tempDir = Directory.systemTemp
          .createTempSync('tina_graph_test_')
          .path;
    });

    tearDown(() {
      Directory(tempDir).deleteSync(recursive: true);
    });

    test('save and load round-trips graph', () async {
      // Build a real graph from the tina repo.
      final original = GraphStore.rebuildFromRepo(repoRoot);
      GraphStore.save(original, tempDir);

      // Verify the file was created.
      expect(File(GraphStore.graphPath(tempDir)).existsSync(), isTrue);

      // Load and compare. Since filePaths are absolute in the original
      // but relative in the serialized form, we compare structure.
      final loaded = GraphStore.load(tempDir);
      expect(loaded, isNotNull);
      expect(loaded!.symbols.length, original.symbols.length);
      expect(loaded.edges.length, original.edges.length);

      // Spot-check a symbol.
      final agentQName = original.symbols.qualifiedNames.firstWhere(
        (q) => q.endsWith('.Agent') && q.contains('agent/agent'),
      );
      expect(loaded.symbols[agentQName], isNotNull);
    });

    test('load returns null when no graph file exists', () {
      expect(GraphStore.load(tempDir), isNull);
    });

    test('load returns null on corrupt file', () {
      File(GraphStore.graphPath(tempDir))
          .parent
          .createSync(recursive: true);
      File(GraphStore.graphPath(tempDir)).writeAsStringSync('not json');
      expect(GraphStore.load(tempDir), isNull);
    });

    test('rebuildFromRepo produces a valid graph', () {
      final graph = GraphStore.rebuildFromRepo(repoRoot);
      expect(graph.symbols.length, greaterThan(0));
      expect(graph.edges, isNotEmpty);
    });

    test('summaries round-trip through save and load', () {
      final original = GraphStore.rebuildFromRepo(repoRoot);
      original.setSummary('lib/agent/agent.dart', 'abc123', 'Core agent loop');
      original.setSummary('lib/llm/provider.dart', 'def456', 'LLM provider interface');
      GraphStore.save(original, tempDir);

      final loaded = GraphStore.load(tempDir);
      expect(loaded, isNotNull);
      expect(loaded!.summaryFor('lib/agent/agent.dart'), 'Core agent loop');
      expect(loaded!.summaryFor('lib/llm/provider.dart'), 'LLM provider interface');
    });

    test('manifest round-trips through save and load', () {
      final original = GraphStore.rebuildFromRepo(repoRoot);
      original.setContentHash('lib/agent/agent.dart', 'hash111');
      original.setContentHash('lib/agent/agent.Agent', 'hash222');
      GraphStore.save(original, tempDir);

      final loaded = GraphStore.load(tempDir);
      expect(loaded, isNotNull);
      expect(loaded!.manifest['lib/agent/agent.dart'], 'hash111');
      expect(loaded!.manifest['lib/agent/agent.Agent'], 'hash222');
    });

    test('load handles graph without summaries or manifest', () {
      final original = GraphStore.rebuildFromRepo(repoRoot);
      GraphStore.save(original, tempDir);

      final loaded = GraphStore.load(tempDir);
      expect(loaded, isNotNull);
      expect(loaded!.summaries, isEmpty);
      expect(loaded!.manifest, isEmpty);
    });

    test('v1 migration discards old summaries', () {
      // Write a v1-format graph file using the real repo so paths resolve.
      final original = GraphStore.rebuildFromRepo(repoRoot);
      final v1Json = {
        'version': 1,
        'symbols': original.symbols.entries.entries
            .map((e) => {'id': e.key, ...e.value.toJson()})
            .toList(),
        'edges': original.edges.map((e) => e.toJson()).toList(),
        'fileHashes': {
          'packages/tina_engine/lib/src/agent/agent.dart': 'oldhash'
        },
        'summaries': {
          'packages/tina_engine/lib/src/agent/agent.dart': 'Old summary text'
        },
      };

      File(GraphStore.graphPath(tempDir))
          .parent
          .createSync(recursive: true);
      File(GraphStore.graphPath(tempDir))
          .writeAsStringSync(jsonEncode(v1Json));

      // Load the file we just wrote. (The old version loaded from
      // repoRoot, which only worked if a stale .tina/graph.json happened
      // to exist there from a prior tina run — on a clean checkout it
      // returned null. No assertion here needs file-backed paths, so
      // resolving against tempDir is fine.)
      final loaded = GraphStore.load(tempDir);
      expect(loaded, isNotNull);
      // v1 summaries should be discarded.
      expect(loaded!.summaries, isEmpty);
      expect(loaded!.manifest, isEmpty);
      // But symbols and edges should load fine.
      expect(loaded!.symbols.length, greaterThan(0));
    });
  });
}
