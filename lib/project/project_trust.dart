import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Default trust behavior for a cwd that has an AGENTS.md but is neither
/// explicitly trusted nor denied. `ask` prompts in the TUI and skips the
/// AGENTS.md injection headless; `always`/`never` skip the prompt.
enum TrustDefault { ask, always, never }

/// Does any `AGENTS.md` exist in [cwd] or one of its ancestors? These are the
/// same files the system-prompt walker would inject, so the gate only prompts
/// when there is actual project context to gate — no noise for plain dirs.
bool hasAgentsMdUpTree(String cwd) {
  var dir = Directory(cwd).absolute;
  while (true) {
    if (File(p.join(dir.path, 'AGENTS.md')).existsSync()) return true;
    final parent = dir.parent;
    if (parent.path == dir.path) return false; // filesystem root
    dir = parent;
  }
}

String _canonicalize(String path) {
  try {
    return Directory(path).resolveSymbolicLinksSync();
  } catch (_) {
    return p.canonicalize(path);
  }
}

/// Persists the set of trusted project directories to
/// `~/.tina/trusted_projects.json`. A corrupt or missing file is treated as
/// an empty set so a bad state never blocks startup. Mirrors the
/// [BackupStore] JSON-store pattern (`lib/tools/atomic_write.dart`).
class ProjectTrustStore {
  ProjectTrustStore(this._file);

  final File _file;

  factory ProjectTrustStore.forTinaDir(Directory tinaDir) =>
      ProjectTrustStore(File(p.join(tinaDir.path, 'trusted_projects.json')));

  Set<String> _load() {
    try {
      if (!_file.existsSync()) return {};
      final decoded = jsonDecode(_file.readAsStringSync());
      if (decoded is! List) return {};
      return decoded.whereType<String>().toSet();
    } catch (_) {
      return {}; // corrupt → start empty rather than block startup
    }
  }

  void _save(Set<String> trusted) {
    try {
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(trusted.toList()..sort()),
        flush: true,
      );
    } catch (_) {
      // Best-effort persistence: a failed write doesn't undo the in-session
      // decision (the caller already has the resolved bool).
    }
  }

  bool isTrusted(String cwd) => _load().contains(_canonicalize(cwd));

  void setTrusted(String cwd, bool trusted) {
    final set = _load();
    final key = _canonicalize(cwd);
    if (trusted) {
      set.add(key);
    } else {
      set.remove(key);
    }
    _save(set);
  }
}

/// Resolve whether [cwd]'s project context (`AGENTS.md`) may be loaded into the
/// system prompt.
///
/// Precedence: an explicit [override] (`--trust` / `--no-trust`) wins outright;
/// a cwd with no `AGENTS.md` up the tree is auto-trusted (nothing to gate); an
/// already-trusted cwd passes; otherwise [defaultMode] decides — `always`
/// trusts, `never` skips, and `ask` prompts via [ask] when there's a UI and
/// skips (returns false) when headless. The store is updated only on an
/// affirmative prompt answer.
Future<bool> resolveProjectTrust({
  required String cwd,
  required ProjectTrustStore store,
  required bool hasUi,
  TrustDefault defaultMode = TrustDefault.ask,
  bool? override,
  Future<bool> Function(String cwd)? ask,
}) async {
  if (override != null) return override;
  if (!hasAgentsMdUpTree(cwd)) return true;
  if (store.isTrusted(cwd)) return true;
  switch (defaultMode) {
    case TrustDefault.always:
      return true;
    case TrustDefault.never:
      return false;
    case TrustDefault.ask:
      if (!hasUi || ask == null) return false;
      final trusted = await ask(cwd);
      if (trusted) store.setTrusted(cwd, true);
      return trusted;
  }
}
