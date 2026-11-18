import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

import '../memory_store_api.dart';

/// Resolves a workspace's git origin: `git remote get-url origin`,
/// normalized into the memory key. Null when the workspace has no
/// origin remote (a fresh init, or a repo pushed nowhere) — the caller
/// decides what a keyless workspace gets (never a shared file).
String? repoOriginFor(String workspace) {
  final result = Process.runSync(
    'git',
    ['remote', 'get-url', 'origin'],
    workingDirectory: workspace,
    runInShell: false,
    stdoutEncoding: systemEncoding,
    stderrEncoding: systemEncoding,
  );
  if (result.exitCode != 0) return null;
  final url = (result.stdout as String).trim();
  if (url.isEmpty) return null;
  try {
    return normalizeRepoOrigin(url);
  } on FormatException {
    return null;
  }
}

/// A stable, filesystem-safe digest of a normalized origin key.
String originHash(String normalizedOrigin) =>
    sha256.convert(utf8.encode(normalizedOrigin)).toString().substring(0, 24);
