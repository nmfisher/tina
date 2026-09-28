/// Sources for the input line's two completion pickers — `/` for the
/// command registry, `@` for file paths. Both implement the console's
/// [CompletionProvider] (`Future<List<String>> complete(String query)`),
/// and both return a possibly-empty list for any query — never an error,
/// never a throw: a missing folder or a failed `git ls-files` just means
/// "no suggestions".
///
/// Completion is a front-end concern: these live in `tina_tui`; the
/// console only supplies the picker machinery.
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tina_console/tina_console.dart';
import 'package:tina_services/tina_services.dart';

/// The `/` source: exact names from the session's [Commands] registry —
/// no scanning, no parsing. The picker hands the query *without* the
/// slash; results carry it (the console configures the command picker
/// with `prependTriggerOnAccept: false`, so nothing re-adds the sigil).
///
/// Read at use, not at construction: the registry is live, so a command
/// published after this source is built still suggests.
final class CommandNameCompletionSource implements CompletionProvider {
  /// The session's command registry.
  final Commands commands;

  const CommandNameCompletionSource(this.commands);

  @override
  Future<List<String>> complete(String query) {
    final all = [for (final c in commands.all) '/${c.name}'];
    if (query.isEmpty) return Future.value(all);
    final prefix = '/$query';
    return Future.value(all.where((c) => c.startsWith(prefix)).toList());
  }
}

/// The `@` source: candidate paths for the token being typed, from `git
/// ls-files` (fast, respects ignore rules) with a bounded directory walk
/// outside a repository. Empty for any query when nothing is enumerable —
/// outside a repository *and* an empty directory are empty lists, not
/// errors.
final class GitFileCompletionSource implements CompletionProvider {
  /// The directory completions are relative to: the working directory of
  /// the git invocation and the root of the walk fallback.
  final String workingDir;

  /// Result cap: enumeration is bounded so a huge tree cannot flood the
  /// picker.
  final int maxCandidates;

  /// Walk-only bound: how deep the fallback walk descends from
  /// [workingDir] (git output is already repo-relative and flat).
  final int maxDepth;

  /// Cached snapshot (3s TTL). Enumeration is the expensive part and the
  /// picker refreshes once per keystroke; the cache bounds it. Never a
  /// permission boundary — everything here is read-only listing.
  List<String>? _cache;
  DateTime? _cacheAt;

  GitFileCompletionSource({
    required this.workingDir,
    this.maxCandidates = 200,
    this.maxDepth = 8,
  });

  @override
  Future<List<String>> complete(String query) async {
    final now = DateTime.now();
    final cached = _cache;
    if (cached == null ||
        _cacheAt == null ||
        now.difference(_cacheAt!) > const Duration(seconds: 3)) {
      _cache = await _enumerate();
      _cacheAt = now;
    }
    final all = _cache ?? const <String>[];
    if (query.isEmpty) return List.of(all);
    return rankFuzzy(query, all);
  }

  /// One bounded snapshot of the candidate set, preferring git.
  Future<List<String>> _enumerate() async {
    final fromGit = await _gitFiles();
    if (fromGit != null) return fromGit;
    return _walk();
  }

  /// `git ls-files --cached --others --exclude-standard` in [workingDir]:
  /// tracked plus untracked-but-not-ignored, repo-relative, depth-free.
  /// Null when git is absent, fails, or the directory is not inside a
  /// work tree — the walk takes over.
  Future<List<String>?> _gitFiles() async {
    try {
      final r = await Process.run(
          'git',
          const [
            'ls-files',
            '--cached',
            '--others',
            '--exclude-standard',
          ],
          workingDirectory: workingDir);
      if (r.exitCode != 0) return null;
      final files = (r.stdout as String)
          .split('\n')
          .where((l) => l.isNotEmpty)
          .take(maxCandidates)
          .toList();
      return files;
    } catch (_) {
      return null; // no git on PATH, or the directory vanished
    }
  }

  /// The fallback outside a repository: a bounded walk — [maxDepth]
  /// levels deep, [maxCandidates] entries, links never followed, the
  /// usual noise directories skipped. Sorted so ties between runs read
  /// the same.
  Future<List<String>> _walk() async {
    const skip = {
      '.git',
      '.dart_tool',
      '.pnpm-store',
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

    Future<void> walk(Directory dir, String prefix, int depth) async {
      if (depth > maxDepth || out.length >= maxCandidates) return;
      List<FileSystemEntity> entries;
      try {
        entries = await dir.list(followLinks: false).toList();
      } catch (_) {
        return; // unreadable branch: pruned, never fatal
      }
      entries.sort((a, b) => a.path.compareTo(b.path));
      for (final e in entries) {
        if (out.length >= maxCandidates) return;
        final name = p.basename(e.path);
        if (skip.contains(name)) continue;
        final rel = prefix.isEmpty ? name : '$prefix/$name';
        // A symlink's linkTarget resolves lazily; treat every link as a
        // file candidate and never descend into one.
        if (e is Directory) {
          out.add('$rel/');
          await walk(e, rel, depth + 1);
        } else {
          out.add(rel);
        }
      }
    }

    await walk(Directory(workingDir), '', 1);
    return out;
  }
}
