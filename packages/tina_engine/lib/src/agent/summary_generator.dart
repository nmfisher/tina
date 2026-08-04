import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tina_index/tina_index.dart';
import 'package:logging/logging.dart';

import '../llm/message.dart';
import '../llm/provider.dart';

final _log = Logger('tina.summary');

const _systemPrompt =
    'You are a concise code summarizer. Respond with only the summary. /no_think';

class SummaryGenerator {
  final LlmProvider provider;
  final String repoRoot;

  SummaryGenerator({required this.provider, required this.repoRoot});

  static const _maxFunctionSource = 3000;
  static const _maxClassSource = 6000;

  /// Count how many LLM calls would be made without executing them.
  static int countPending(CodeGraph graph, String repoRoot) {
    final staleFiles = _filesWithStaleSymbolsStatic(graph, repoRoot);
    var count = 0;
    for (final relPath in staleFiles) {
      count += _countFileCalls(graph, relPath, repoRoot);
    }
    return count;
  }

  static List<String> _filesWithStaleSymbolsStatic(
      CodeGraph graph, String repoRoot) {
    final seenFiles = <String>{};
    final result = <String>[];
    for (final entry in graph.symbols.entries.entries) {
      final relPath = p.relative(entry.value.filePath, from: repoRoot);
      if (seenFiles.contains(relPath)) continue;
      seenFiles.add(relPath);
      if (_fileHasStaleSymbols(graph, relPath, repoRoot)) {
        result.add(relPath);
      }
    }
    return result;
  }

  static bool _fileHasStaleSymbols(
      CodeGraph graph, String relPath, String repoRoot) {
    final absPath = p.join(repoRoot, relPath);
    final file = File(absPath);
    if (!file.existsSync()) return false;

    // Check file-level hash.
    final fileHash = CodeHasher.hashBytes(file.readAsBytesSync());
    if (!graph.hasSummary(fileHash)) return true;

    // Check symbol-level hashes.
    final fileEntries = graph.symbols.entries.entries
        .where((e) => p.relative(e.value.filePath, from: repoRoot) == relPath);
    for (final e in fileEntries) {
      final source = GraphTraversal.readSource(e.value);
      if (source == null || source.trim().isEmpty) continue;
      if (e.value.kind == SymbolKind.method ||
          e.value.kind == SymbolKind.function) {
        if (source.length <= _maxFunctionSource &&
            !graph.hasSummary(CodeHasher.hashText(source))) {
          return true;
        }
      } else if (e.value.kind == SymbolKind.class_ ||
          e.value.kind == SymbolKind.mixin ||
          e.value.kind == SymbolKind.enum_ ||
          e.value.kind == SymbolKind.extension) {
        if (!graph.hasSummary(CodeHasher.hashText(source))) {
          return true;
        }
      }
    }
    return false;
  }

  static int _countFileCalls(CodeGraph graph, String relPath, String repoRoot) {
    final absPath = p.join(repoRoot, relPath);
    final file = File(absPath);
    if (!file.existsSync()) return 0;

    var calls = 0;
    final fileEntries = graph.symbols.entries.entries
        .where((e) => p.relative(e.value.filePath, from: repoRoot) == relPath)
        .toList();

    // Functions and methods.
    for (final e in fileEntries) {
      final kind = e.value.kind;
      if (kind != SymbolKind.method && kind != SymbolKind.function) continue;
      final source = GraphTraversal.readSource(e.value);
      if (source == null ||
          source.trim().isEmpty ||
          source.length > _maxFunctionSource) continue;
      final hash = CodeHasher.hashText(source);
      if (!graph.hasSummary(hash)) calls++;
    }

    // Classes, mixins, enums, extensions.
    for (final e in fileEntries) {
      final kind = e.value.kind;
      if (kind != SymbolKind.class_ &&
          kind != SymbolKind.mixin &&
          kind != SymbolKind.enum_ &&
          kind != SymbolKind.extension) continue;
      final source = GraphTraversal.readSource(e.value);
      if (source == null || source.trim().isEmpty) continue;
      final hash = CodeHasher.hashText(source);
      if (!graph.hasSummary(hash)) calls++;
    }

    // File level.
    final fileHash = CodeHasher.hashBytes(file.readAsBytesSync());
    if (!graph.hasSummary(fileHash)) calls++;

    return calls;
  }

  /// Generate hierarchical summaries for stale files.
  /// Returns count of summaries generated.
  Future<int> generateIncremental(CodeGraph graph) async {
    final staleFiles = _filesWithStaleSymbols(graph);
    if (staleFiles.isEmpty) return 0;

    var count = 0;
    final total = staleFiles.length;
    for (var i = 0; i < staleFiles.length; i++) {
      final relPath = staleFiles[i];
      stderr.writeln('[${i + 1}/$total] $relPath');
      final generated = await _summarizeFileHierarchy(graph, relPath);
      stderr.writeln('  -> $generated summaries');
      count += generated;
      GraphStore.save(graph, repoRoot);
    }
    return count;
  }

  List<String> _filesWithStaleSymbols(CodeGraph graph) {
    return _filesWithStaleSymbolsStatic(graph, repoRoot);
  }

  Future<int> _summarizeFileHierarchy(
      CodeGraph graph, String relPath) async {
    final fileEntries = graph.symbols.entries.entries
        .where(
            (e) => p.relative(e.value.filePath, from: repoRoot) == relPath)
        .toList();

    var count = 0;

    // 1. Functions and methods (leaf level).
    for (final e in fileEntries) {
      final kind = e.value.kind;
      if (kind != SymbolKind.method && kind != SymbolKind.function) continue;
      final source = GraphTraversal.readSource(e.value);
      if (source == null ||
          source.trim().isEmpty ||
          source.length > _maxFunctionSource) continue;
      final hash = CodeHasher.hashText(source);
      if (graph.hasSummary(hash)) {
        graph.setContentHash(e.key, hash);
        continue;
      }
      final summary = await _summarize(source, 'function');
      if (summary != null) {
        graph.setSummary(e.key, hash, summary);
        count++;
      }
    }

    // 2. Classes, mixins, enums, extensions.
    for (final e in fileEntries) {
      final kind = e.value.kind;
      if (kind != SymbolKind.class_ &&
          kind != SymbolKind.mixin &&
          kind != SymbolKind.enum_ &&
          kind != SymbolKind.extension) continue;
      final source = GraphTraversal.readSource(e.value);
      if (source == null || source.trim().isEmpty) continue;
      final hash = CodeHasher.hashText(source);
      if (graph.hasSummary(hash)) {
        graph.setContentHash(e.key, hash);
        continue;
      }

      String? summary;
      if (source.length <= _maxClassSource) {
        summary = await _summarize(source, 'class');
      } else {
        // Compose from member summaries.
        final parentName = e.value.name;
        final members = fileEntries
            .where((me) =>
                me.value.parentName == parentName &&
                graph.manifest.containsKey(me.key))
            .map((me) {
          final memberSummary = graph.summaryFor(me.key);
          return '- ${me.value.name}: $memberSummary';
        }).join('\n');
        if (members.isNotEmpty) {
          summary = await _summarizeFromMembers(parentName, members);
        } else {
          summary = await _summarize(
              source.substring(0, _maxClassSource), 'class');
        }
      }
      if (summary != null) {
        graph.setSummary(e.key, hash, summary);
        count++;
      }
    }

    // 3. File level — compose from top-level symbol summaries.
    final absPath = p.join(repoRoot, relPath);
    final fileHash = CodeHasher.hashBytes(File(absPath).readAsBytesSync());
    if (graph.hasSummary(fileHash)) {
      graph.setContentHash(relPath, fileHash);
      return count;
    }

    final topLevel = fileEntries
        .where((e) =>
            e.value.parentName == null &&
            graph.manifest.containsKey(e.key))
        .map((e) {
      final symSummary = graph.summaryFor(e.key);
      return '- ${e.value.name} (${e.value.kind.name}): $symSummary';
    }).join('\n');

    String? fileSummary;
    if (topLevel.isNotEmpty) {
      fileSummary = await _summarizeFileFromSymbols(topLevel);
    } else {
      final content =
          File(p.join(repoRoot, relPath)).readAsStringSync();
      if (content.trim().isNotEmpty && content.length <= _maxClassSource) {
        fileSummary = await _summarize(content, 'file');
      }
    }
    if (fileSummary != null) {
      graph.setSummary(relPath, fileHash, fileSummary);
      count++;
    }

    return count;
  }

  Future<String?> _summarize(String source, String kind) async {
    final prompt = kind == 'function'
        ? 'Summarize this Dart function in one sentence. Be specific:\n\n$source'
        : kind == 'class'
            ? 'Summarize this Dart type in one sentence. Focus on responsibility:\n\n$source'
            : 'Summarize this Dart file in one or two sentences:\n\n$source';
    return _callLlm(prompt);
  }

  Future<String?> _summarizeFromMembers(
      String className, String members) async {
    return _callLlm(
        'Dart class "$className" members:\n$members\n\nSummarize the class in one sentence.');
  }

  Future<String?> _summarizeFileFromSymbols(String summaries) async {
    return _callLlm(
        'This file contains:\n$summaries\n\nSummarize the file in one or two sentences.');
  }

  Future<String?> _callLlm(String prompt) async {
    try {
      final stream = provider.send(
        system: _systemPrompt,
        messages: [
          Message(role: Role.user, content: [TextBlock(prompt)]),
        ],
        tools: const [],
      );

      final buf = StringBuffer();
      final done = Completer<void>();
      Object? err;

      stream.listen(
        (event) {
          if (event is TextDelta) {
            buf.write(event.text);
          } else if (event is StreamError) {
            err = event.error;
          }
        },
        onDone: () {
          if (!done.isCompleted) done.complete();
        },
        onError: (Object e) {
          err = e;
          if (!done.isCompleted) done.complete();
        },
      );

      await done.future;
      if (err != null) return null;
      return buf.toString().trim();
    } catch (e, st) {
      _log.warning('summary generation failed', e, st);
      return null;
    }
  }
}
