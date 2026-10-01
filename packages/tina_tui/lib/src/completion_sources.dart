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

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:tina_console/tina_console.dart';
import 'package:tina_host/tina_host.dart';

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
  Future<List<String>> complete(String query) async {
    final space = query.indexOf(' ');
    if (space >= 0) {
      final name = query.substring(0, space);
      final complete = commands[name]?.complete;
      if (complete == null) return [];
      final arguments = query.substring(space + 1);
      return [
        for (final suggestion in await complete(arguments)) '/$name $suggestion'
      ];
    }
    final all = [for (final c in commands.all) '/${c.name}'];
    if (query.isEmpty) return all;
    final prefix = '/$query';
    return all.where((c) => c.startsWith(prefix)).toList();
  }
}

/// The `@` source searches the full file listing, with git ignore rules inside
/// repositories and a directory walk elsewhere. Only the picker viewport is
/// bounded; neither enumeration nor ranking may make a file undiscoverable.
final class GitFileCompletionSource implements CompletionProvider {
  /// The directory completions are relative to: the working directory of
  /// the git invocation and the root of the walk fallback.
  final String workingDir;

  static const cacheTtl = Duration(seconds: 3);
  final DateTime Function() clock;

  /// Cached snapshot (3s TTL). Enumeration is the expensive part and the
  /// picker refreshes once per keystroke; the cache bounds it. Never a
  /// permission boundary — everything here is read-only listing.
  List<String>? _cache;
  DateTime? _cacheAt;
  Future<List<String>>? _loading;

  GitFileCompletionSource({
    required this.workingDir,
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  @override
  Future<List<String>> complete(String query) async {
    final all = await _files();
    if (query.isEmpty) return _spreadAcrossFolders(all);
    return rankFuzzy(query, all);
  }

  Future<List<String>> _files() {
    if (_cache != null &&
        _cacheAt != null &&
        clock().difference(_cacheAt!) < cacheTtl) {
      return Future.value(_cache!);
    }
    // Keystrokes share an in-flight scan. Timestamp the completed snapshot so
    // a slow listing does not expire before the next query can use it.
    return _loading ??= _enumerate(workingDir).then((files) {
      _cache = files;
      _cacheAt = clock();
      _loading = null;
      return files;
    });
  }

  Future<List<String>> _enumerate(String directory) async {
    final fromGit = await _gitFiles(directory);
    if (fromGit != null) return fromGit;
    return _walk(directory);
  }

  /// `git ls-files --cached --others --exclude-standard` in [workingDir]:
  /// tracked plus untracked-but-not-ignored, repo-relative, depth-free.
  /// Null when git is absent, fails, or the directory is not inside a
  /// work tree — the walk takes over.
  Future<List<String>?> _gitFiles(String directory) async {
    try {
      final results = await Future.wait([
        Process.run(
            'git',
            const [
              'ls-files',
              '--cached',
              '--others',
              '--exclude-standard',
              '-z'
            ],
            workingDirectory: directory,
            stdoutEncoding: utf8),
        // Git lists submodules as directory entries, not their files. Identify
        // the gitlinks explicitly, then enumerate initialized submodules using
        // their own ignore rules (including untracked files).
        Process.run('git', const ['ls-files', '--stage', '-z'],
            workingDirectory: directory, stdoutEncoding: utf8),
      ]);
      final r = results.first;
      if (r.exitCode != 0) return null;
      final files = (r.stdout as String)
          .split('\u0000')
          .where((l) => l.isNotEmpty)
          .toSet();
      if (results.last.exitCode == 0) {
        final submodules = <String>{};
        for (final entry in (results.last.stdout as String).split('\u0000')) {
          if (!entry.startsWith('160000 ')) continue;
          final tab = entry.indexOf('\t');
          if (tab >= 0) submodules.add(entry.substring(tab + 1));
        }
        for (final name in submodules) {
          files.remove(name);
          final path = p.join(directory, name);
          if (await FileSystemEntity.isLink(path) ||
              !await Directory(path).exists()) continue;
          // A gitlink can be a plain/empty directory before initialization.
          // Running git there would query the parent repo again.
          final initialized =
              await FileSystemEntity.type(p.join(path, '.git')) !=
                  FileSystemEntityType.notFound;
          files.addAll((await (initialized ? _enumerate(path) : _walk(path)))
              .map((file) => '$name/$file'));
        }
      }
      return files.toList()..sort();
    } catch (_) {
      return null; // no git on PATH, or the directory vanished
    }
  }

  /// Like the legacy source, skip generated/dependency directories outside
  /// git. Do not impose a depth limit or follow directory symlinks.
  Future<List<String>> _walk(String directory) async {
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

    Future<void> walk(Directory dir, String prefix) async {
      List<FileSystemEntity> entries;
      try {
        entries = await dir.list(followLinks: false).toList();
      } catch (_) {
        return; // unreadable branch: pruned, never fatal
      }
      entries.sort((a, b) => a.path.compareTo(b.path));
      for (final e in entries) {
        final name = p.basename(e.path);
        if (name == '.git' || (e is Directory && skip.contains(name))) continue;
        final rel = prefix.isEmpty ? name : '$prefix/$name';
        // A symlink's linkTarget resolves lazily; treat every link as a
        // file candidate and never descend into one.
        if (e is Directory) {
          await walk(e, rel);
        } else {
          out.add(rel);
        }
      }
    }

    await walk(Directory(directory), '');
    return out;
  }

  /// Restore the legacy bare-@ spread across top-level folders, but retain
  /// every file so scrolling can reach the entire list. A large dot-directory
  /// must not bury all source folders on the first screen.
  List<String> _spreadAcrossFolders(List<String> files) {
    final buckets = <String, List<String>>{};
    for (final file in files) {
      final slash = file.indexOf('/');
      final key = slash < 0 ? '' : file.substring(0, slash);
      (buckets[key] ??= []).add(file);
    }
    int priority(String key) => key.isEmpty
        ? 1
        : key.startsWith('.')
            ? 2
            : 0;
    var keys = buckets.keys.toList()
      ..sort((a, b) {
        final rank = priority(a).compareTo(priority(b));
        return rank == 0 ? a.compareTo(b) : rank;
      });
    final result = <String>[];
    for (var round = 0; keys.isNotEmpty; round++) {
      final next = <String>[];
      for (final key in keys) {
        final bucket = buckets[key]!;
        result.add(bucket[round]);
        if (round + 1 < bucket.length) next.add(key);
      }
      keys = next;
    }
    return result;
  }
}
