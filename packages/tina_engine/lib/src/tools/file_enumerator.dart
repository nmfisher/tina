import 'dart:io';

import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;

import 'process_runner.dart';

final _log = Logger('tina.tools.files');

/// Directories never enumerated by [WalkFileEnumerator]. The git path honours
/// .gitignore via `git ls-files`, but when that fails we still don't want to
/// flood results with build artifacts.
const skipDirs = {
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

/// File-path glob matcher with `**`-aware path semantics.
///
/// - `*`  matches any sequence of chars **except `/`**.
/// - `**` matches any chars including `/`.
/// - `**/` matches zero or more directory components.
/// - `?`  matches any single non-slash char.
///
/// This differs from `globMatch` in `lib/permissions/policy.dart`, which is
/// tuned for permission-rule matching (where `*` may or may not cross `/`
/// depending on the tool). Keep them separate so neither has to grow flags
/// the other doesn't need.
bool fileGlobMatch(String pattern, String input) {
  final sb = StringBuffer(r'^');
  var i = 0;
  while (i < pattern.length) {
    final c = pattern[i];
    if (c == '*') {
      if (i + 1 < pattern.length && pattern[i + 1] == '*') {
        if (i + 2 < pattern.length && pattern[i + 2] == '/') {
          // `**/` — zero or more directory components
          sb.write(r'(?:[^/]+/)*');
          i += 3;
          continue;
        }
        sb.write(r'.*');
        i += 2;
        continue;
      }
      sb.write(r'[^/]*');
      i++;
    } else if (c == '?') {
      sb.write(r'[^/]');
      i++;
    } else if (r'.+^$(){}[]|\'.contains(c)) {
      sb.write('\\$c');
      i++;
    } else {
      sb.write(c);
      i++;
    }
  }
  sb.write(r'$');
  return RegExp(sb.toString()).hasMatch(input);
}

/// Enumerates the files a search/glob tool should consider under [root], as
/// paths relative to [root]. Production wires [RepoFileEnumerator]; tests
/// inject a fake so glob/grep can be driven without touching disk or git.
abstract class FileEnumerator {
  Future<List<String>> enumerate(String root);
}

/// Enumerates by walking the directory tree with `dart:io`, skipping
/// well-known build dirs ([skipDirs]) and following no symlinks. Used directly
/// when git is unavailable, and as [RepoFileEnumerator]'s fallback.
class WalkFileEnumerator implements FileEnumerator {
  const WalkFileEnumerator();

  @override
  Future<List<String>> enumerate(String root) async => _walk(root);
}

List<String> _walk(String root) {
  final out = <String>[];
  void walk(Directory d, String prefix) {
    try {
      for (final e in d.listSync(followLinks: false)) {
        final name = p.basename(e.path);
        if (skipDirs.contains(name)) continue;
        final rel = prefix.isEmpty ? name : '$prefix/$name';
        if (e is File) {
          out.add(rel);
        } else if (e is Directory) {
          walk(e, rel);
        }
      }
    } catch (e) {
      _log.warning('failed to list ${d.path}, skipping subtree', e);
    }
  }

  walk(Directory(root), '');
  return out;
}

/// Enumerates files in repo order, honouring .gitignore: tries
/// `git ls-files --cached --others --exclude-standard` first, and falls back to
/// [WalkFileEnumerator] when git is unavailable or exits non-zero.
///
/// The [fallback] is itself a [FileEnumerator] (default [WalkFileEnumerator])
/// so the git→walk decision is unit-testable with two fakes and no real I/O.
class RepoFileEnumerator implements FileEnumerator {
  final ProcessRunner processRunner;
  final FileEnumerator fallback;

  RepoFileEnumerator({
    ProcessRunner? processRunner,
    FileEnumerator? fallback,
  })  : processRunner = processRunner ?? const IoProcessRunner(),
        fallback = fallback ?? const WalkFileEnumerator();

  @override
  Future<List<String>> enumerate(String root) async {
    try {
      final res = await processRunner.run(
        'git',
        const ['ls-files', '--cached', '--others', '--exclude-standard'],
        workingDirectory: root,
      );
      if (res.exitCode == 0) {
        return res.stdout.split('\n').where((l) => l.isNotEmpty).toList();
      }
    } catch (e) {
      _log.fine('git ls-files failed, falling back to walk', e);
    }
    return fallback.enumerate(root);
  }
}

/// Convenience top-level wrapper around [RepoFileEnumerator]. Retained for
/// call sites that enumerate ad-hoc without holding an instance; the tools
/// themselves inject a [FileEnumerator] instead.
Future<List<String>> enumerateRepoFiles(String root) =>
    RepoFileEnumerator().enumerate(root);
