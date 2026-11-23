/// Sources for the input line's completion pickers — `/` for the
/// command registry, `@` for file paths, Tab in `!` mode for shell command
/// names and argument paths. All implement the console's
/// [CompletionProvider] (`Future<List<String>> complete(String query)`),
/// and all return a possibly-empty list for any query — never an error,
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

/// The `/` source: command metadata from the session connection —
/// no scanning, no parsing. The picker hands the query *without* the
/// slash; results carry it (the console configures the command picker
/// with `prependTriggerOnAccept: false`, so nothing re-adds the sigil).
///
/// Read at use, not at construction: the registry is live, so a command
/// published after this source is built still suggests.
final class CommandNameCompletionSource implements CompletionProvider {
  final SessionConnection session;

  const CommandNameCompletionSource(this.session);

  @override
  Future<List<String>> complete(String query) async {
    final space = query.indexOf(' ');
    if (space >= 0) {
      final name = query.substring(0, space);
      final arguments = query.substring(space + 1);
      return [
        for (final suggestion in await session.completeCommand(name, arguments))
          '/$name $suggestion'
      ];
    }
    final all = [for (final c in session.commands) '/${c.name}'];
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

/// Curated common shell commands offered alongside the PATH scan — things
/// users type constantly, some of them actual shell builtins (`cd`, `jobs`),
/// some just ubiquitous binaries (`git`, `grep`). Ordered by everyday use so
/// an empty query lists the useful names first.
const shellBuiltins = <String>[
  'cd',
  'ls',
  'pwd',
  'echo',
  'cat',
  'less',
  'head',
  'tail',
  'grep',
  'find',
  'rg',
  'sed',
  'awk',
  'sort',
  'uniq',
  'wc',
  'tr',
  'cut',
  'tee',
  'xargs',
  'mkdir',
  'rm',
  'cp',
  'mv',
  'ln',
  'touch',
  'chmod',
  'chown',
  'stat',
  'file',
  'tar',
  'gzip',
  'gunzip',
  'zip',
  'unzip',
  'curl',
  'wget',
  'ssh',
  'scp',
  'git',
  'dart',
  'flutter',
  'node',
  'npm',
  'pnpm',
  'yarn',
  'python3',
  'pip',
  'cargo',
  'rustc',
  'go',
  'make',
  'cmake',
  'jq',
  'which',
  'type',
  'man',
  'alias',
  'export',
  'source',
  'env',
  'printenv',
  'ps',
  'kill',
  'jobs',
  'fg',
  'bg',
  'history',
  'time',
  'date',
  'whoami',
  'hostname',
  'uname',
  'df',
  'du',
  'top',
  'open',
  'code',
];

/// The `!`-mode command-word source: a curated list of common commands plus
/// every executable on PATH. The PATH scan runs once per distinct PATH
/// value per process and is cached — a picker refresh per keystroke must
/// not stat the filesystem each time, and PATH does not change mid-session.
///
/// Results carry the leading `!`: the picker's anchor sits on the `!` of a
/// bang line, so accepting replaces `!par` with `!parted` plus the trailing
/// space the picker appends.
final class ShellCommandCompletionSource implements CompletionProvider {
  /// The `PATH` value to scan; defaults to the environment's.
  final String? pathEnv;

  /// Extra names ranked alongside the builtins and PATH executables.
  final Iterable<String> extra;

  const ShellCommandCompletionSource({this.pathEnv, this.extra = const []});

  // One scan per distinct PATH per process (keyed so tests with fixture
  // PATHs do not poison each other). Never a permission boundary.
  static final Map<String, Future<List<String>>> _scans = {};

  @override
  Future<List<String>> complete(String query) async {
    final names = await _names();
    if (query.isEmpty) {
      // The whole listing (curated block first): the picker scrolls, and a
      // cap would silently make later curated names undiscoverable.
      return [for (final n in names) '!$n'];
    }
    return [for (final n in rankFuzzy(query, names)) '!$n'];
  }

  Future<List<String>> _names() async {
    final path = pathEnv ?? Platform.environment['PATH'] ?? '';
    return _scans[path] ??= _scan(path);
  }

  Future<List<String>> _scan(String path) async {
    final separator = Platform.isWindows ? ';' : ':';
    final executableExtensions = Platform.isWindows
        ? const ['.exe', '.bat', '.cmd', '.com']
        : const <String>[];
    final seen = <String>{};
    final dirs = path.split(separator).where((d) => d.isNotEmpty);
    final groups = await Future.wait([for (final dir in dirs) _listDir(dir)]);
    for (final entries in groups) {
      for (final entry in entries) {
        if (entry is Directory) continue;
        var name = p.basename(entry.path);
        if (executableExtensions.isNotEmpty) {
          final dot = name.lastIndexOf('.');
          if (dot <= 0) continue;
          if (!executableExtensions
              .contains(name.substring(dot).toLowerCase())) {
            continue;
          }
          name = name.substring(0, dot);
        } else {
          // POSIX: only executables are command candidates. stat() follows
          // links, so a symlink to an executable counts.
          try {
            final st = await entry.stat();
            // 0x49 == 0o111: any execute bit set.
            if ((st.mode & 0x49) == 0) continue;
          } catch (_) {
            continue;
          }
        }
        if (name.isNotEmpty) seen.add(name);
      }
    }
    // Curated names first in their given order (builtins like `cd` need
    // not exist on PATH to be suggestable); PATH adds the rest, deduped,
    // alphabetically.
    final curated = <String>{...shellBuiltins, ...extra};
    final ordered = [...shellBuiltins, ...extra].toSet().toList();
    final pathNames = seen.difference(curated).toList()..sort();
    return [...ordered, ...pathNames];
  }

  /// One PATH directory's entries. An unreadable or vanished directory, or
  /// one that stalls, contributes nothing — a bad PATH entry never breaks
  /// completion.
  static Future<List<FileSystemEntity>> _listDir(String dir) async {
    try {
      return await Directory(dir)
          .list(followLinks: true)
          .toList()
          .timeout(const Duration(seconds: 2),
              onTimeout: () => <FileSystemEntity>[]);
    } catch (_) {
      return const [];
    }
  }
}

/// The `!`-mode path-word source: the `@` file machinery wrapped for word
/// position. The picker's query for an argument word is the raw word, which
/// may open (and, when fully typed, close) with a quote; the query is
/// completed unquoted and every result is re-quoted so the accepted line
/// still parses as one word — a completed path containing spaces stays
/// quoted.
final class BangPathCompletionSource implements CompletionProvider {
  final GitFileCompletionSource files;

  BangPathCompletionSource({required String workingDir})
      : files = GitFileCompletionSource(workingDir: workingDir);

  @override
  Future<List<String>> complete(String query) async {
    final quote = (query.startsWith("'") || query.startsWith('"'))
        ? query.substring(0, 1)
        : null;
    final bare = quote == null ? query : _stripQuotes(query, quote);
    final ranked = await files.complete(bare);
    if (quote == null) return ranked;
    return [for (final path in ranked) _requoted(path, quote)];
  }

  static String _stripQuotes(String word, String quote) {
    var t = word.substring(1);
    if (t.endsWith(quote)) {
      t = t.length <= 1 ? '' : t.substring(0, t.length - 1);
    }
    return t;
  }

  /// Re-quote [path] with [quote] unless the path embeds that quote char,
  /// in which case use the other quote (single-quoted strings cannot
  /// escape a single quote at all).
  static String _requoted(String path, String quote) {
    final other = quote == "'" ? '"' : "'";
    final q = path.contains(quote) && !path.contains(other) ? other : quote;
    return '$q$path$q';
  }
}
