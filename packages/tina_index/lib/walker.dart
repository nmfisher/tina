import 'dart:io';

class DartFileWalker {
  final String repoRoot;

  const DartFileWalker({required this.repoRoot});

  Future<List<String>> walk() async {
    final fromGit = await _runGitLs();
    if (fromGit != null) return fromGit;
    return _walkFallback();
  }

  Future<List<String>?> _runGitLs() async {
    try {
      final res = await Process.run(
        'git',
        ['ls-files', '--cached', '--others', '--exclude-standard'],
        workingDirectory: repoRoot,
      );
      if (res.exitCode != 0) return null;
      return (res.stdout as String)
          .split('\n')
          .where((l) => l.isNotEmpty && l.endsWith('.dart'))
          .toList();
    } catch (_) {
      return null;
    }
  }

  Future<List<String>> _walkFallback() async {
    const skip = {
      '.git',
      '.dart_tool',
      'node_modules',
      'build',
      'dist',
    };
    final out = <String>[];
    await _walk(Directory(repoRoot), '', skip, out);
    return out;
  }

  Future<void> _walk(
      Directory dir, String prefix, Set<String> skip, List<String> out) async {
    try {
      await for (final e in dir.list(followLinks: false)) {
        final name = e.path.split('/').last;
        if (skip.contains(name)) continue;
        final rel = prefix.isEmpty ? name : '$prefix/$name';
        if (e is File) {
          if (rel.endsWith('.dart')) out.add(rel);
        } else if (e is Directory) {
          await _walk(e, rel, skip, out);
        }
      }
    } catch (_) {}
  }
}
