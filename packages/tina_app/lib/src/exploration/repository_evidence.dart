import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:tina_engine/tina_engine.dart';
import 'models.dart';

/// Git-aware bounded scan of fresh working-tree files. Git is used only to
/// enumerate names, with fixed arguments; no shell, hooks, builds, or writes.
/// Non-Git folders fail explicitly rather than silently ignoring ignore rules.
class RepositoryEvidenceSource implements ProjectEvidenceSource {
  final String root;
  final SandboxedFileSystem sandbox;
  final ProcessRunner processes;
  final int maxFiles;
  final int maxBytes;
  final int maxFileBytes;
  RepositoryEvidenceSource({
    required this.root,
    required this.sandbox,
    this.processes = const IoProcessRunner(),
    this.maxFiles = 5000,
    this.maxBytes = 8 * 1024 * 1024,
    this.maxFileBytes = 128 * 1024,
  }) {
    if (maxFiles <= 0 || maxBytes <= 0 || maxFileBytes <= 0) {
      throw ArgumentError('Evidence limits must be positive');
    }
  }

  @override
  Future<EvidenceScan> collect(
    String question,
    JudgmentCancellation cancellation,
    void Function(String) progress,
  ) async {
    final gaps = <String>[];
    final evidence = <ProjectEvidence>[];
    if (cancellation.isCancelled)
      return EvidenceScan([], 0, ['Scan cancelled.']);
    await sandbox.validatePath(root);
    final realRoot = await Directory(root).resolveSymbolicLinks();
    final names = await _files(cancellation, gaps);
    final terms = _terms(question);
    if (terms.isEmpty)
      return EvidenceScan([], 0, [...gaps, 'No searchable terms in question.']);
    // Filename/symbol hints first so a bounded scan prioritizes likely areas.
    names.sort((a, b) {
      final rank = _matches(b, terms).compareTo(_matches(a, terms));
      return rank != 0 ? rank : a.compareTo(b);
    });
    var bytes = 0;
    var scanned = 0;
    var skipped = 0;
    for (final name in names) {
      if (cancellation.isCancelled) {
        gaps.add('Scan cancelled.');
        break;
      }
      if (!_eligible(name)) {
        skipped++;
        continue;
      }
      final path = p.join(realRoot, name);
      try {
        await sandbox.validatePath(path);
        // Reject links even if they point within the project. Reject special
        // files before opening: a FIFO must never hang a repository scan.
        if (await FileSystemEntity.type(path, followLinks: false) !=
                FileSystemEntityType.file ||
            p.normalize(await File(path).resolveSymbolicLinks()) !=
                p.normalize(p.absolute(path))) {
          skipped++;
          continue;
        }
        final before = await File(path).stat();
        if (before.size > maxFileBytes) {
          skipped++;
          continue;
        }
        if (bytes + before.size > maxBytes) {
          gaps.add('Scan byte limit reached.');
          break;
        }
        final data = <int>[];
        await for (final chunk in File(path).openRead(0, maxFileBytes + 1)) {
          if (cancellation.isCancelled) break;
          data.addAll(chunk);
        }
        bytes += data.length;
        if (cancellation.isCancelled) break;
        if (bytes > maxBytes) {
          gaps.add('Scan byte limit reached while a file was changing.');
          break;
        }
        final after = await File(path).stat();
        if (data.length > maxFileBytes ||
            before.size != after.size ||
            before.modified != after.modified ||
            data.contains(0)) {
          skipped++;
          continue;
        }
        final text = utf8.decode(data);
        scanned++;
        final lines = const LineSplitter().convert(text);
        final filenameRank = _matches(name, terms);
        final hits = <(int, int)>[];
        for (var i = 0; i < lines.length; i++) {
          final score = _matches(lines[i], terms);
          if (score > 0) hits.add((i, score));
        }
        if (hits.isEmpty && filenameRank > 0 && lines.isNotEmpty)
          hits.add((0, 0));
        hits.sort(
          (a, b) => b.$2 != a.$2 ? b.$2.compareTo(a.$2) : a.$1.compareTo(b.$1),
        );
        final selected = <int>[];
        for (final hit in hits) {
          if (selected.any((i) => (hit.$1 - i).abs() < 16)) continue;
          final start = (hit.$1 - 5).clamp(0, lines.length);
          final end = (hit.$1 + 20).clamp(0, lines.length);
          final excerpt = lines.sublist(start, end).join('\n');
          // Minified/generated giant lines aren't useful to the heavy agent.
          if (excerpt.length > 4000) {
            skipped++;
            continue;
          }
          evidence.add(
            ProjectEvidence(
              name,
              start + 1,
              excerpt,
              hit.$2 + filenameRank * 2,
            ),
          );
          selected.add(hit.$1);
          if (selected.length == 2) break;
        }
        // Retain only a bounded pool while scanning, not every matching file.
        evidence.sort((a, b) {
          final score = b.lexicalScore.compareTo(a.lexicalScore);
          return score != 0 ? score : a.path.compareTo(b.path);
        });
        if (evidence.length > 24) evidence.removeRange(24, evidence.length);
        if (scanned % 100 == 0) progress('Exploring: scanned $scanned files');
      } on FileSystemException {
        skipped++;
      } on SandboxViolation {
        skipped++;
      } on FormatException {
        skipped++;
      }
    }
    gaps.add(
      'Lexical shortlist: at most 24 excerpts, two per file; semantic matches without shared terms may be missed.',
    );
    if (skipped > 0)
      gaps.add(
        '$skipped files/windows skipped (excluded, binary, oversized, changed, inaccessible, or symlink).',
      );
    return EvidenceScan(evidence, scanned, gaps);
  }

  Future<List<String>> _files(
    JudgmentCancellation cancellation,
    List<String> gaps,
  ) async {
    if (cancellation.isCancelled) return [];
    final paths = <String>{};
    RunningProcess? process;
    StreamSubscription<List<int>>? stdout;
    StreamSubscription<List<int>>? stderr;
    final done = Completer<void>();
    var truncated = false;
    var failed = false;
    var timedOut = false;
    void finish() {
      if (!done.isCompleted) done.complete();
    }

    void stop() {
      process?.kill();
      finish();
    }

    final detach = cancellation.listen(stop);
    final timer = Timer(const Duration(seconds: 10), () {
      timedOut = true;
      gaps.add('File enumeration deadline reached.');
      stop();
    });
    try {
      final starting = processes.start('git', const [
        '--no-optional-locks',
        '-c',
        'core.fsmonitor=false',
        'ls-files',
        '-z',
        '--cached',
        '--others',
        '--exclude-standard',
        '--',
        '.',
      ], workingDirectory: root);
      // Observe a late start after cancellation and close it immediately.
      starting.then((p) {
        if (done.isCompleted) p.kill();
      }, onError: (Object _) {});
      process = await Future.any<RunningProcess?>([
        starting,
        done.future.then((_) => null),
      ]);
      if (process == null) return [];
      var count = 0;
      final pending = <int>[];
      stderr = process.stderr.listen((_) {}, onError: (Object _) {});
      stdout = process.stdout.listen(
        (chunk) {
          if (done.isCompleted) return;
          for (final byte in chunk) {
            if (++count > 4 * 1024 * 1024 ||
                pending.length > 4096 ||
                paths.length >= maxFiles) {
              truncated = true;
              stop();
              return;
            }
            if (byte == 0) {
              try {
                paths.add(utf8.decode(pending));
              } on FormatException {
                gaps.add('Non-UTF8 filename skipped.');
              }
              pending.clear();
            } else {
              pending.add(byte);
            }
          }
        },
        onError: (Object _) {
          failed = true;
          stop();
        },
        onDone: finish,
      );
      await done.future;
      if (!truncated && !timedOut && !cancellation.isCancelled) {
        final code = await process.exitCode.timeout(
          const Duration(seconds: 1),
          onTimeout: () => -1,
        );
        if (code != 0 || failed) {
          throw const JudgmentException(JudgmentFailure.invalidRequest);
        }
      }
      if (truncated)
        gaps.add('File enumeration capped at $maxFiles paths / 4 MiB.');
      return paths.toList();
    } on ProcessException {
      throw const JudgmentException(JudgmentFailure.invalidRequest);
    } finally {
      timer.cancel();
      detach();
      process?.kill();
      await stdout?.cancel();
      await stderr?.cancel();
    }
  }
}

const _excluded = {
  'node_modules',
  'build',
  'dist',
  'target',
  'vendor',
  'venv',
  '__pycache__',
};
const _extensions = {
  '.dart',
  '.rs',
  '.go',
  '.py',
  '.js',
  '.jsx',
  '.ts',
  '.tsx',
  '.c',
  '.cc',
  '.cpp',
  '.h',
  '.hpp',
  '.java',
  '.kt',
  '.swift',
  '.m',
  '.mm',
  '.cs',
  '.rb',
  '.php',
  '.sh',
  '.sql',
  '.html',
  '.css',
  '.scss',
  '.vue',
  '.svelte',
  '.md',
  '.toml',
  '.yaml',
  '.yml',
  '.json',
};
bool _eligible(String name) {
  if (p.isAbsolute(name) || name.contains('\\')) return false;
  final parts = name.split('/');
  if (parts.any((part) => part.startsWith('.') || _excluded.contains(part)))
    return false;
  final lower = name.toLowerCase();
  if (RegExp(
    r'(^|[/_.-])(secret|secrets|credentials|credential|token|private)([/_.-]|$)',
  ).hasMatch(lower))
    return false;
  return _extensions.contains(p.extension(lower)) && !lower.endsWith('.lock');
}

List<String> _terms(String question) => RegExp(r'[\p{L}\p{N}_]+', unicode: true)
    .allMatches(
      question
          .replaceAllMapped(RegExp(r'([a-z])([A-Z])'), (m) => '${m[1]} ${m[2]}')
          .toLowerCase(),
    )
    .map((m) => m[0]!)
    .where(
      (s) =>
          s.length > 1 &&
          !const {
            'where',
            'does',
            'this',
            'that',
            'the',
            'and',
            'for',
            'how',
            'what',
            'which',
            'implemented',
            'implementation',
            'find',
            'locate',
            'code',
            'with',
            'from',
            'are',
            'can',
            'you',
            'our',
          }.contains(s),
    )
    .take(16)
    .toSet()
    .toList();
int _matches(String text, List<String> terms) {
  final lower = text.toLowerCase();
  return terms.where(lower.contains).length;
}
