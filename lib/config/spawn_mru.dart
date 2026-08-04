import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:tina_engine/tina_engine.dart';

/// The filename (under the tina user-data dir) holding the spawn
/// most-recently-used model list. A JSON array of `"provider/model"` refs,
/// most-recent first.
const _kSpawnMruFilename = 'spawn_mru.json';

/// How many refs to remember. Bounded so the file stays small and the list
/// stays representative of recent usage.
const _kSpawnMruCap = 16;

/// The tina user-data directory, overridable for tests.
Directory _dir(Map<String, String> env, Directory? tinaDir) =>
    tinaDir ?? tinaDirFromEnv(env);

File _spawnMruFile(Map<String, String> env, Directory? tinaDir) =>
    File(p.join(_dir(env, tinaDir).path, _kSpawnMruFilename));

/// Load the spawn most-recently-used model list (most-recent first).
///
/// A missing file returns an empty list. A parse failure warns on stderr and
/// returns an empty list — a bad MRU file never blocks `/spawn`, mirroring the
/// user-config recovery policy.
List<String> loadSpawnMru({
  required Map<String, String> env,
  Directory? tinaDir,
}) {
  final file = _spawnMruFile(env, tinaDir);
  if (!file.existsSync()) return const [];
  try {
    final decoded = jsonDecode(file.readAsStringSync());
    if (decoded is! List) return const [];
    return decoded.whereType<String>().toList(growable: false);
  } catch (e) {
    stderr.writeln('warning: failed to parse ${file.path}: $e');
    return const [];
  }
}

/// Record that [ref] was just used in `/spawn`, moving it to the front of the
/// most-recently-used list (deduplicating any prior entry) and capping the
/// stored list to [_kSpawnMruCap]. Best-effort: a write failure warns on stderr
/// and is otherwise ignored — MRU is a convenience, not correctness-critical.
void recordSpawnMru(
  String ref, {
  required Map<String, String> env,
  Directory? tinaDir,
}) {
  try {
    final dir = _dir(env, tinaDir);
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final updated = [ref, ...loadSpawnMru(env: env, tinaDir: dir).where((r) => r != ref)];
    final capped = updated.length > _kSpawnMruCap
        ? updated.sublist(0, _kSpawnMruCap)
        : updated;
    _spawnMruFile(env, dir).writeAsStringSync(jsonEncode(capped));
  } catch (e) {
    stderr.writeln('warning: failed to record spawn MRU: $e');
  }
}
