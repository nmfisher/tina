import 'dart:io';

import 'package:path/path.dart' as p;

/// Directories never shown in the summary tree — VCS/tool state and build
/// output carry no orientation value.
const Set<String> _skipDirs = {
  '.git',
  '.tina',
  '.dart_tool',
  '.idea',
  'build',
  'node_modules',
  'dist',
  'target',
  '.venv',
};

/// How deep the tree section descends below the repo root.
const int _treeDepth = 2;

/// Commits shown in the `recent:` section.
const int _recentCommits = 5;

/// The `<repo>` block injected into every prompt's `<environment>` funnel:
/// branch + HEAD, dirty counts, the last few commits, and a shallow
/// directory tree. Everything here is derived locally (a handful of git
/// plumbing calls + one directory walk) — no LLM, no tool calls — so the
/// agent starts a conversation already knowing the repo state it would
/// otherwise re-derive via `git status` / `ls` round trips.
///
/// Returns null when [projectRoot] is not a git repository (or git is
/// unavailable), in which case the block is simply omitted. Never throws —
/// a summary failure must not break prompt assembly.
String? repoSummaryBlock(String projectRoot) {
  try {
    return _build(projectRoot);
  } catch (_) {
    return null;
  }
}

String? _build(String projectRoot) {
  final inside = _git(projectRoot, [
    'rev-parse',
    '--is-inside-work-tree',
  ]);
  if (inside == null || inside.trim() != 'true') return null;

  final buf = StringBuffer('<repo>');
  // Branch + HEAD. --show-current is empty on a detached HEAD; fall back to
  // the abbreviated ref so the line still says something useful.
  var branch = _git(projectRoot, ['branch', '--show-current'])?.trim() ?? '';
  if (branch.isEmpty) {
    branch = _git(projectRoot, ['rev-parse', '--abbrev-ref', 'HEAD'])?.trim() ??
        '(unknown)';
  }
  final head = _git(projectRoot, ['rev-parse', '--short', 'HEAD'])?.trim();
  if (head == null || head.isEmpty) {
    // A repo with no commits yet: still useful (branch + tree), skip the
    // commit-dependent lines.
    buf
      ..writeln()
      ..writeln('branch: $branch (no commits yet)');
  } else {
    final subject =
        _git(projectRoot, ['log', '-1', '--pretty=format:%s'])?.trim() ?? '';
    buf
      ..writeln()
      ..writeln('branch: $branch @ $head ($subject)');
    final statusCounts = _statusCounts(projectRoot);
    if (statusCounts != null) {
      buf.writeln('status: $statusCounts');
    }
    final log = _git(projectRoot,
        ['log', '-$_recentCommits', '--pretty=format:%h %s']);
    if (log != null && log.trim().isNotEmpty) {
      buf
        ..writeln('recent:')
        ..write(log.trim().split('\n').map((l) => '  $l').join('\n'));
    }
  }

  final tree = _treeSection(projectRoot);
  if (tree != null) {
    buf
      ..writeln()
      ..writeln('tree:')
      ..write(tree);
  }
  buf.writeln('\n</repo>');
  return buf.toString();
}

/// `"2 modified, 1 untracked"` from `status --porcelain`, or null when the
/// worktree is clean (clean needs no line at all).
String? _statusCounts(String root) {
  final out = _git(root, ['status', '--porcelain']);
  if (out == null || out.trim().isEmpty) return null;
  var modified = 0;
  var untracked = 0;
  for (final line in out.split('\n')) {
    if (line.startsWith('??')) {
      untracked++;
    } else if (line.trim().isNotEmpty) {
      modified++;
    }
  }
  final parts = <String>[];
  if (modified > 0) parts.add('$modified modified');
  if (untracked > 0) parts.add('$untracked untracked');
  return parts.isEmpty ? null : parts.join(', ');
}

/// Indented two-level directory listing with per-directory direct file
/// counts and a `[package]` marker where a package manifest lives, or null
/// when the repo has no visible subdirectories.
String? _treeSection(String root) {
  final buf = StringBuffer();

  void walk(String rel, int depth) {
    if (depth > _treeDepth) return;
    final dir = Directory(p.join(root, rel));
    if (!dir.existsSync()) return;
    final entries = dir.listSync(followLinks: false)
      ..sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    for (final e in entries) {
      final name = p.basename(e.path);
      if (e is! Directory) continue;
      if (name.startsWith('.') || _skipDirs.contains(name)) continue;
      final subRel = rel.isEmpty ? name : '$rel/$name';
      var files = 0;
      for (final f in e.listSync(followLinks: false)) {
        if (f is File) files++;
      }
      final isPackage = File(p.join(e.path, 'pubspec.yaml')).existsSync() ||
          File(p.join(e.path, 'package.json')).existsSync();
      buf.writeln('${'  ' * (depth - 1)}$subRel/  '
          '($files file${files == 1 ? '' : 's'}${isPackage ? ' [package]' : ''})');
      walk(subRel, depth + 1);
    }
  }

  walk('', 1);
  if (buf.isEmpty) return null;
  return buf.toString().trimRight();
}

/// Runs git in [dir], returning trimmed stdout on success (exit 0), null on
/// any failure. The codebase's other private `_git` helpers (sidecar repo,
/// write_summary, environment inputs) are the precedent for a
/// self-contained sync helper.
String? _git(String dir, List<String> args) {
  final result = Process.runSync('git', ['-C', dir, ...args]);
  if (result.exitCode != 0) return null;
  return result.stdout as String;
}
