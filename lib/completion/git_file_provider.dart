import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fuzzy_ranker/fuzzy_ranker.dart';
import 'package:path/path.dart' as p;

/// Lists files in the working directory, honoring .gitignore. Uses
/// `git ls-files --cached --others --exclude-standard` when a git repo is
/// available, falling back to a plain walk that skips well-known build
/// directories. Results are cached after the first call; [invalidate] drops
/// the cache.
class GitFileCompletionProvider implements CompletionProvider {
  final String workingDir;
  final int maxResults;
  final void Function(Object error, StackTrace stack)? onError;

  List<String>? _cache;
  Future<List<String>>? _loading;

  GitFileCompletionProvider({
    String? workingDir,
    this.maxResults = 50,
    this.onError,
  }) : workingDir = workingDir ?? Directory.current.path;

  @override
  Future<List<String>> complete(String query) async {
    final files = await _files();
    if (query.isEmpty) {
      return files.length <= maxResults ? files : files.sublist(0, maxResults);
    }
    final ranked = rankFuzzy(query, files);
    return ranked.length <= maxResults
        ? ranked
        : ranked.sublist(0, maxResults);
  }

  void invalidate() {
    _cache = null;
    _loading = null;
  }

  /// Eagerly enumerate files and populate the cache. If [onFile] is provided,
  /// it is called with the running count after each file is discovered.
  /// If the cache is already populated, this is a no-op.
  Future<void> prewarm({void Function(int count)? onFile}) async {
    if (_cache != null) return;
    final files = <String>[];
    final fromGit = await _streamGitLs(files, onFile: onFile);
    if (!fromGit) {
      await _walkFallbackTo(files, onFile: onFile);
    }
    _cache = files;
  }

  Future<List<String>> _files() {
    final cached = _cache;
    if (cached != null) return Future.value(cached);
    return _loading ??= _enumerate().then((list) {
      _cache = list;
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
