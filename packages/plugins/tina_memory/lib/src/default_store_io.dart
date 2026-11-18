import 'dart:io';

import 'package:path/path.dart' as p;

import '../memory_store_api.dart';
import 'origin_key.dart';
import 'sqlite_memory_store.dart';

/// Where rolling memory lives: `~/.tina/memory/` — NOT under the
/// workspace, because the repo database is keyed by ORIGIN and shared
/// by every checkout (issue 94's cross-checkout learning). One file
/// per normalized origin (hashed for the filename), plus `global.db`
/// for machine-true facts.
String defaultMemoryRoot([Map<String, String>? environment]) {
  final env = environment ?? Platform.environment;
  final home = env['HOME'] ?? '.';
  return p.join(home, '.tina', 'memory');
}

/// The repo database's file name for one normalized origin: a stable
/// SHA-256 prefix of the origin key — origins contain slashes and
/// colons that never survive as one filename cleanly on every host.
String memoryFileForOrigin(String normalizedOrigin) =>
    'repo-${originHash(normalizedOrigin)}.db';

/// The global database's file name.
const memoryGlobalFile = 'global.db';

/// Opens (creating parents) the memory pair for [workspace]:
/// the origin-keyed repo database plus the global one. The origin is
/// resolved by running `git remote get-url origin` in [workspace]; a
/// workspace with no origin still gets the global store, and the repo
/// store falls back to a per-workspace sandbox file so nothing is
/// silently shared across UNRELATED projects.
MemoryStorePair openDefaultMemoryStores(String workspace,
    {Map<String, String>? environment}) {
  final root = defaultMemoryRoot(environment);
  try {
    Directory(root).createSync(recursive: true);
  } on Object catch (e) {
    throw MemoryStoreException('cannot create $root', e);
  }
  final global = SqliteMemoryStore.open(
      p.join(root, memoryGlobalFile), MemoryScope.global);

  final origin = repoOriginFor(workspace);
  final MemoryStoreApi project;
  if (origin == null) {
    // No origin: a sandbox memory that is still origin-KEYED (the
    // key is just this workspace's own identity) — never shared.
    final key = normalizeRepoOrigin(
        'localhost${p.separator}${_sandboxName(workspace)}');
    project = SqliteMemoryStore.open(
        p.join(root, memoryFileForOrigin(key)), MemoryScope.project);
  } else {
    project = SqliteMemoryStore.open(
        p.join(root, memoryFileForOrigin(origin)), MemoryScope.project);
  }
  return MemoryStorePair(project, global);
}

String _sandboxName(String workspace) {
  var name = p.basename(p.normalize(workspace)).replaceAll(
      RegExp(r'[^A-Za-z0-9._-]'), '-');
  return name.isEmpty ? 'workspace' : name;
}
