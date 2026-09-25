import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fuzzy_ranker/fuzzy_ranker.dart';
import 'package:path/path.dart' as p;

/// Lists files in the working directory, honoring .gitignore. Uses
/// `git ls-files --cached --others --exclude-standard` when a git repo is
/// available, falling back to a plain walk that skips well-known build
/// directories. Results are cached for [cacheTtl] so the @ picker reflects
/// files moved or added since the last listing while per-keystroke queries
/// don't re-run git; [invalidate] drops the cache immediately.
class GitFileCompletionProvider implements CompletionProvider {
  /// How long a cached listing stays fresh. Short enough that a picker
  /// opened after files moved shows the current tree; long enough that the
  /// queries fired on every keystroke while it's open all hit the cache.
  static const cacheTtl = Duration(seconds: 3);

  final String workingDir;
  final int maxResults;
  final void Function(Object error, StackTrace stack)? onError;

  /// Injectable so TTL behavior is testable without sleeping.
  final DateTime Function() clock;

  List<String>? _cache;
  DateTime? _cachedAt;
  Future<List<String>>? _loading;

  GitFileCompletionProvider({
    String? workingDir,
    this.maxResults = 50,
    this.onError,
    DateTime Function()? clock,
  })  : clock = clock ?? DateTime.now,
        workingDir = workingDir ?? Directory.current.path;

  bool get _cacheFresh {
    final cachedAt = _cachedAt;
    return _cache != null &&
        cachedAt != null &&
        clock().difference(cachedAt) < cacheTtl;
  }

  @override
  Future<List<String>> complete(String query) async {
    final files = await _files();
    if (query.isEmpty) return _pageFiles(files);
    final ranked = rankFuzzy(query, files);
    return ranked.length <= maxResults
        ? ranked
        : ranked.sublist(0, maxResults);
  }

  /// The unfiltered bare-`@` listing. A raw slice of the enumeration would
  /// mirror `git ls-files` directory grouping — e.g. a repo whose first
  /// tracked entries are hundreds of dotfiles would show nothing else — so
  /// the page is spread across top-level directories instead: one file per
  /// directory per round, source dirs before dot-dirs, then alphabetically.
  /// A file at the root counts as its own "directory" so root files stay
  /// reachable too.
  List<String> _pageFiles(List<String> files) {
    if (files.length <= maxResults) return files;
    final buckets = <String, List<String>>{};
    for (final f in files) {
      final top = f.contains('/') ? f.split('/').first : '';
      (buckets[top] ??= []).add(f);
    }
    final keys = buckets.keys.toList()..sort(_bucketOrder);
    final page = <String>[];
    var remaining = maxResults;
    // Round-robin one file per bucket per round so a directory with
    // thousands of entries cannot crowd out the rest of the page.
    for (var round = 0; remaining > 0; round++) {
      var served = 0;
      for (final key in keys) {
        if (remaining == 0) break;
        final bucket = buckets[key]!;
        if (round < bucket.length) {
          page.add(bucket[round]);
          remaining--;
          served++;
        }
      }
      if (served == 0) break; // every bucket exhausted
    }
    return page;
  }

  /// Sort key for the round-robin buckets: named source directories first
  /// (alphabetical), then root files, then dot-dirs. Keeps the page biased
  /// toward code a user is likely to @-mention.
  static int _bucketOrder(String a, String b) {
    int rank(String k) {
      if (k.isEmpty) return 1; // root files
      if (k.startsWith('.')) return 2; // dot dirs (.tickets, .github, ...)
      return 0; // source dirs
    }

    final r = rank(a).compareTo(rank(b));
    if (r != 0) return r;
    return a.compareTo(b);
  }

  void invalidate() {
    _cache = null;
    _cachedAt = null;
    _loading = null;
  }

  /// Eagerly enumerate files and populate the cache. If [onFile] is provided,
  /// it is called with the running count after each file is discovered.
  /// If the cache is fresh, this is a no-op.
  Future<void> prewarm({void Function(int count)? onFile}) async {
    if (_cacheFresh) return;
    final files = <String>[];
    final fromGit = await _streamGitLs(files, onFile: onFile);
    if (!fromGit) {
      await _walkFallbackTo(files, onFile: onFile);
    }
    _cache = files;
    _cachedAt = clock();
  }

  Future<List<String>> _files() {
    if (_cacheFresh) return Future.value(_cache!);
    // Reuse an in-flight enumeration, but never a completed one: once the
    // TTL expires a new listing must actually run, so _loading is cleared
    // when it settles.
    return _loading ??= _enumerate().then((list) {
      _cache = list;
      _cachedAt = clock();
      _loading = null;
      return list;
    });
  }

  Future<List<String>> _enumerate() async {
    final fromGit = await _runGitLs();
    if (fromGit != null) return fromGit;
    return _walkFallback();
  }

  Future<List<String>?> _runGitLs() async {
    try {
      final res = await Process.run(
        'git',
        ['ls-files', '--cached', '--others', '--exclude-standard'],
        workingDirectory: workingDir,
      );
      if (res.exitCode != 0) return null;
      return (res.stdout as String)
          .split('\n')
          .where((l) => l.isNotEmpty)
          .toList();
    } catch (e, st) {
      if (onError != null) onError!(e, st);
      return null;
    }
  }

  Future<List<String>> _walkFallback() async {
    const skip = {
      '.git',
      '.dart_tool',
      'node_modules',
      'build',
      '.next',
      'target',
      'dist',
      '.venv',
      'venv',
      '__pycache__',
    };
    final out = <String>[];
    Future<void> walk(Directory d, String prefix) async {
      try {
        await for (final e in d.list(followLinks: false)) {
          final name = p.basename(e.path);
          if (skip.contains(name)) continue;
          final rel = prefix.isEmpty ? name : '$prefix/$name';
          if (e is File) {
            out.add(rel);
          } else if (e is Directory) {
            await walk(e, rel);
          }
        }
      } catch (e, st) {
        if (onError != null) onError!(e, st);
      }
    }

    await walk(Directory(workingDir), '');
    return out;
  }

  /// Streaming variant of [_runGitLs] that adds files to [sink] as they
  /// arrive and calls [onFile] with the running count. Returns true if git
  /// succeeded.
  Future<bool> _streamGitLs(
    List<String> sink, {
    void Function(int count)? onFile,
  }) async {
    Process? proc;
    try {
      proc = await Process.start(
        'git',
        ['ls-files', '--cached', '--others', '--exclude-standard'],
        workingDirectory: workingDir,
      );
    } catch (e, st) {
      if (onError != null) onError!(e, st);
      return false;
    }

    var count = 0;
    final lines = proc.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter());
    await for (final line in lines) {
      if (line.isEmpty) continue;
      sink.add(line);
      count++;
      onFile?.call(count);
    }
    await proc.exitCode;
    return true;
  }

  /// Variant of [_walkFallback] that reports progress via [onFile].
  Future<void> _walkFallbackTo(
    List<String> sink, {
    void Function(int count)? onFile,
  }) async {
    const skip = {
      '.git',
      '.dart_tool',
      'node_modules',
      'build',
      '.next',
      'target',
      'dist',
      '.venv',
      'venv',
      '__pycache__',
    };
    Future<void> walk(Directory d, String prefix) async {
      try {
        await for (final e in d.list(followLinks: false)) {
          final name = p.basename(e.path);
          if (skip.contains(name)) continue;
          final rel = prefix.isEmpty ? name : '$prefix/$name';
          if (e is File) {
            sink.add(rel);
            onFile?.call(sink.length);
          } else if (e is Directory) {
            await walk(e, rel);
          }
        }
      } catch (e, st) {
        if (onError != null) onError!(e, st);
      }
    }

    await walk(Directory(workingDir), '');
  }
}
