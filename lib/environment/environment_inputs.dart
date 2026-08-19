import 'dart:io';

import 'environment_record.dart';

/// The environment region's inputs: the record itself plus every dependency
/// manifest/lockfile present in the repo. Hashed with the same two signals as
/// a summary region (docs/proposals/environment_agent.md, "Region
/// integration"):
///
/// - **committed** — a digest over the blob hashes at HEAD
///   (`git rev-parse HEAD:<path>`), so a committed dependency bump changes it;
/// - **dirty** — a digest over `git status --porcelain -- <inputs>`, so an
///   uncommitted edit is visible without a commit.
///
/// The record itself lives in the gitignored `.tina/` sidecar, so git sees
/// neither its existence nor its edits — its content is hashed directly into
/// the committed digest instead of going through the blob/p porcelain
/// signals. Outside a git repo both degrade to a content digest of the files
/// on disk — the same fallback a never-committed summary dir relies on.
class EnvironmentInputs {
  const EnvironmentInputs();

  /// Manifest/lockfile candidates, per ecosystem. Only the ones that exist are
  /// inputs; a repo typically matches one pair.
  static const _candidates = <String>[
    'pubspec.yaml',
    'pubspec.lock',
    'package.json',
    'package-lock.json',
    'yarn.lock',
    'pnpm-lock.yaml',
    'go.mod',
    'go.sum',
    'Cargo.toml',
    'Cargo.lock',
    'requirements.txt',
    'Pipfile.lock',
    'pyproject.toml',
    'Gemfile',
    'Gemfile.lock',
    'pom.xml',
    'build.gradle',
  ];

  /// The input files for [projectRoot], sorted, existing ones only. The record
  /// is NOT listed here (it is measured by content, not through git) — editing
  /// it is still what makes the region stale, via [measure].
  List<String> files(String projectRoot) {
    final out = <String>[];
    for (final name in _candidates) {
      if (File('$projectRoot/$name').existsSync()) out.add(name);
    }
    return out;
  }

  /// The record's content hash line, mixed into the committed digest. The
  /// record is gitignored under `.tina/`, so git's blob/porcelain signals
  /// can't see it — its bytes are hashed directly instead.
  String _recordLine(String projectRoot) {
    final file = EnvironmentRecord.fileFor(projectRoot);
    if (!file.existsSync()) return 'record:(absent)';
    try {
      return 'record:${_fnv1a(file.readAsStringSync())}';
    } on FileSystemException {
      return 'record:(unreadable)';
    }
  }

  /// Measure the two signals now. [commit] is the repo's HEAD sha (empty when
  /// there are no commits yet); [committed] and [dirty] are the digests the
  /// tracking entry records and the stale check compares.
  EnvironmentInputState measure(String projectRoot) {
    final inputs = files(projectRoot);
    final recordLine = _recordLine(projectRoot);
    final inRepo = _gitOk(projectRoot, ['rev-parse', '--is-inside-work-tree']);
    final commit = inRepo ? _git(projectRoot, ['rev-parse', 'HEAD']) : '';
    if (!inRepo) {
      // No repo: hash the contents. The dirty signal is meaningless without
      // git, so it stays empty and staleness rides on content alone.
      final buf = StringBuffer()..writeln(recordLine);
      for (final f in inputs) {
        final file = File('$projectRoot/$f');
        if (file.existsSync()) buf.writeln('$f:${_fnv1a(file.readAsStringSync())}');
      }
      return EnvironmentInputState(
          commit: '', committed: _fnv1a(buf.toString()), dirty: '');
    }
    final blobHashes = StringBuffer()..writeln(recordLine);
    for (final f in inputs) {
      final hash = _gitOrNull(projectRoot, ['rev-parse', 'HEAD:$f']);
      blobHashes.writeln('$f:${hash ?? '(absent)'}');
    }
    final porcelain =
        _git(projectRoot, ['status', '--porcelain', '--', ...inputs]);
    return EnvironmentInputState(
      commit: commit,
      committed: _fnv1a(blobHashes.toString()),
      // '' (known clean) vs a hash of the porcelain output — the same
      // clean/dirty distinction the summary manifest records.
      dirty: porcelain.isEmpty ? '' : _fnv1a(porcelain),
    );
  }

  bool _gitOk(String dir, List<String> args) =>
      Process.runSync('git', ['-C', dir, ...args]).exitCode == 0;

  String _git(String dir, List<String> args) {
    final result = Process.runSync('git', ['-C', dir, ...args]);
    return (result.stdout as String).trim();
  }

  String? _gitOrNull(String dir, List<String> args) {
    final result = Process.runSync('git', ['-C', dir, ...args]);
    if (result.exitCode != 0) return null;
    final out = (result.stdout as String).trim();
    return out.isEmpty ? null : out;
  }
}

/// The measured state of the environment region's inputs at one point in time.
class EnvironmentInputState {
  final String commit;
  final String committed;
  final String dirty;

  const EnvironmentInputState({
    required this.commit,
    required this.committed,
    required this.dirty,
  });
}

/// FNV-1a 64-bit over [s], as hex — the same dependency-free digest the
/// summary sidecar uses for dirty digests.
String _fnv1a(String s) {
  var hash = 0xcbf29ce484222325;
  for (final code in s.codeUnits) {
    hash ^= code;
    hash = (hash * 0x100000001b3) & 0x7fffffffffffffff;
  }
  return hash.toRadixString(16);
}
