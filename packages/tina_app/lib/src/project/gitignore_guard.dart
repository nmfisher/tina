import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Session transcripts live in `<cwd>/.tina/sessions/` — inside the repo's
/// working tree. This module is the startup guard for that: find the repo's
/// root, check whether its `.gitignore` already covers `.tina`, and remember
/// the repos where the user declined so they aren't re-asked every launch.

/// Walk up from [cwd] looking for a `.git` entry (directory, or the file a
/// worktree/submodule uses). Returns the containing directory, or null when
/// cwd is not inside a git repo (no ask — there's no `.gitignore` to update).
String? gitRepoRootFor(String cwd) {
  var dir = Directory(cwd).absolute;
  while (true) {
    final git = FileSystemEntity.typeSync(p.join(dir.path, '.git'));
    if (git != FileSystemEntityType.notFound) return dir.path;
    final parent = dir.parent;
    if (parent.path == dir.path) return null; // filesystem root
    dir = parent;
  }
}

/// Whether any `.gitignore` [lines] entry ignores `.tina`. Pragmatic pattern
/// match: a non-comment, non-negated line whose pattern — after stripping a
/// root anchor `/`, a `**/` prefix, and a trailing `/` — is exactly `.tina`
/// or ends with `/.tina`. Covers the shapes people actually write
/// (`.tina`, `.tina/`, `/.tina/`, `**/.tina`).
bool gitignoreCoversTina(List<String> lines) {
  for (var raw in lines) {
    var line = raw.trim();
    if (line.isEmpty || line.startsWith('#') || line.startsWith('!')) continue;
    if (line.startsWith('/')) line = line.substring(1);
    if (line.startsWith('**/')) line = line.substring(3);
    if (line.endsWith('/')) line = line.substring(0, line.length - 1);
    if (line == '.tina' || line.endsWith('/.tina')) return true;
  }
  return false;
}

/// Does the `.gitignore` at [repoRoot] already cover `.tina`? False when no
/// `.gitignore` exists yet (the ask then offers to create one).
bool gitignoreCoversTinaAt(String repoRoot) {
  final f = File(p.join(repoRoot, '.gitignore'));
  if (!f.existsSync()) return false;
  try {
    return gitignoreCoversTina(f.readAsLinesSync());
  } on FileSystemException {
    return false;
  }
}

/// Append `.tina/` to [gitignore] (creating it if absent), preserving a
/// trailing newline. Best-effort for the caller on failure.
void addTinaToGitignore(File gitignore) {
  final exists = gitignore.existsSync();
  final current = exists ? gitignore.readAsStringSync() : '';
  final needsLeadingNewline =
      exists && current.isNotEmpty && !current.endsWith('\n');
  gitignore.parent.createSync(recursive: true);
  gitignore.writeAsStringSync(
    '${needsLeadingNewline ? '\n' : ''}.tina/\n',
    mode: FileMode.append,
    flush: true,
  );
}

String _canonicalize(String path) {
  try {
    return Directory(path).resolveSymbolicLinksSync();
  } catch (_) {
    return p.canonicalize(path);
  }
}

/// Persists the set of repo roots where the user answered "don't ask again"
/// to `~/.tina/gitignore_declined.json`. Mirrors [ProjectTrustStore]: a
/// corrupt or missing file is an empty set so bad state never blocks
/// startup, and a failed write never undoes the in-session decision.
class GitignoreAskStore {
  GitignoreAskStore(this._file);

  final File _file;

  factory GitignoreAskStore.forTinaDir(Directory tinaDir) =>
      GitignoreAskStore(File(p.join(tinaDir.path, 'gitignore_declined.json')));

  Set<String> _load() {
    try {
      if (!_file.existsSync()) return {};
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! List) return {};
      return decoded.whereType<String>().toSet();
    } catch (_) {
      return {};
    }
  }

  void _save(Set<String> declined) {
    try {
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(declined.toList()..sort()),
        flush: true,
      );
    } catch (_) {
      // Best-effort persistence.
    }
  }

  bool isDeclined(String repoRoot) =>
      _load().contains(_canonicalize(repoRoot));

  void setDeclined(String repoRoot, bool declined) {
    final set = _load();
    final key = _canonicalize(repoRoot);
    if (declined) {
      set.add(key);
    } else {
      set.remove(key);
    }
    _save(set);
  }
}
