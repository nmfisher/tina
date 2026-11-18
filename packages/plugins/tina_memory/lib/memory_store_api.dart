/// The memory-store contract, with no sqlite anywhere: the interface
/// the tools, the CLI, the hot tier and the answer cache consume, and
/// the portable value types every implementation shares.
///
/// `sqlite_memory_store.dart`'s [SqliteMemoryStore] implements this
/// natively; an in-memory twin serves tests and, eventually, the wasm
/// engine through the opener seam. This library must stay importable
/// where `dart:ffi` cannot go.
///
/// Keying: one database per repo ORIGIN (the git remote URL,
/// normalized), never per absolute path — every checkout, clone and
/// worktree of the same repo shares one memory. One additional global
/// database holds machine-true facts. The store itself is
/// scope-agnostic: a single file holds both `project` and `global`
/// rows when it is the global database, or only project rows when it
/// is a repo database; promotion (issue 94: manual only) moves an
/// entry between them.
library;

/// The fixed entry categories. `paths` (where things live), `structure`
/// (how the repo is organized), `decisions` (what was chosen and why),
/// `gotchas` (what bites), `facts` (everything else durable).
enum MemoryCategory {
  paths,
  structure,
  decisions,
  gotchas,
  facts;

  String get name => switch (this) {
        MemoryCategory.paths => 'paths',
        MemoryCategory.structure => 'structure',
        MemoryCategory.decisions => 'decisions',
        MemoryCategory.gotchas => 'gotchas',
        MemoryCategory.facts => 'facts',
      };

  static MemoryCategory parse(String name) => switch (name) {
        'paths' => MemoryCategory.paths,
        'structure' => MemoryCategory.structure,
        'decisions' => MemoryCategory.decisions,
        'gotchas' => MemoryCategory.gotchas,
        'facts' => MemoryCategory.facts,
        _ => throw FormatException('unknown memory category: $name'),
      };
}

/// Which tier an entry lives in. Project rows are born in the repo
/// database; global rows live in the global database and are only
/// ever created by explicit promotion (or a global remember).
enum MemoryScope {
  project,
  global;

  String get name => switch (this) {
        MemoryScope.project => 'project',
        MemoryScope.global => 'global',
      };

  static MemoryScope parse(String name) => switch (name) {
        'project' => MemoryScope.project,
        'global' => MemoryScope.global,
        _ => throw FormatException('unknown memory scope: $name'),
      };
}

/// One memory row. Mutable by design (issue 94: revise, don't
/// duplicate) — everything but [id] and [createdAt] can change, and
/// [updatedAt]/[updatedBy]/[lastRecalled]/[recallCount] track the
/// row's life for the revision guard and the heat ranking.
final class MemoryEntry {
  const MemoryEntry({
    required this.id,
    required this.scope,
    required this.category,
    required this.text,
    required this.createdAt,
    required this.updatedAt,
    required this.updatedBy,
    this.lastRecalled,
    this.recallCount = 0,
  });

  final int id;
  final MemoryScope scope;
  final MemoryCategory category;
  final String text;

  /// UTC row creation; never changes.
  final DateTime createdAt;

  /// UTC last revision; the revision guard's token.
  final DateTime updatedAt;

  /// The session id that last wrote the row.
  final String updatedBy;

  /// UTC last time a recall/lookup surfaced this row; null when it has
  /// never been recalled. Feeds the hot tier's heat ranking.
  final DateTime? lastRecalled;

  /// How many times recall surfaced this row. Feeds heat.
  final int recallCount;

  @override
  String toString() =>
      '#$id ${scope.name}/${category.name} '
      '(recalled $recallCount) $text';
}

/// A revise whose target changed under the writer: [current] is what
/// the row says NOW. The store returned it instead of overwriting;
/// the caller (agent or human) decides whether to redo the revise
/// against the new text. One timestamp check, no silent data loss.
final class MemoryRevisionConflict implements Exception {
  const MemoryRevisionConflict(this.current);
  final MemoryEntry current;

  @override
  String toString() =>
      'memory entry #${current.id} changed since it was read '
      '(now: ${current.text}); revise again against the current text '
      'if your change still applies';
}

/// The store surface the tools, CLI, hot tier and answer cache use.
/// One store owns one file. Rows are mutable (revise, forget, promote
/// move rows between databases) but revisions are guarded.
abstract interface class MemoryStoreApi {
  /// The store file's path (store-native string; `:memory:` in tests).
  String get file;

  /// Which tier this database serves. A global store answers `global`,
  /// a repo store `project`; promotion between tiers moves rows
  /// between STORES (see [MemoryStorePair]).
  MemoryScope get scope;

  /// Add an entry; returns the stored row with id filled in.
  /// `updatedBy` is the writing session's id.
  MemoryEntry remember(String text,
      {required MemoryCategory category, required String updatedBy});

  /// Revise an entry's text (and optionally category). [expected] is
  /// the `updatedAt` the writer last saw: when the row moved on since,
  /// nothing is written and a [MemoryRevisionConflict] carries the
  /// current row back.
  MemoryEntry revise(int id, String text,
      {required DateTime expected, required String updatedBy,
      MemoryCategory? category});

  /// Delete an entry. Returns the deleted row, or null when [id] is
  /// unknown (idempotent forget).
  MemoryEntry? forget(int id);

  /// Fetch one entry by id (also the read that arms the revision
  /// guard: hand `entry.updatedAt` back as the revise's [expected]).
  MemoryEntry? entry(int id);

  /// Keyword search: entries whose text matches every term
  /// (case-insensitive substring), newest-updated first, at most
  /// [limit]. Recalling BUMPS HEAT: matched rows get `last_recalled`
  /// and `recall_count` updated (durable, not just in the result).
  List<MemoryEntry> recall(String query, {int limit = 20});

  /// Every entry, ordered by heat (the hot tier's input), at most
  /// [limit]. Heat = recall recency + recall count; never-recalled
  /// rows rank by recency of update so fresh knowledge still surfaces.
  List<MemoryEntry> hottest({int limit = 100});

  /// Every entry, newest-updated first (the CLI's list view).
  List<MemoryEntry> list({MemoryCategory? category});

  /// The scoreboard: total entries, entries by category, recalls
  /// served, and (when the answer cache rides this database) cache
  /// telemetry. Stable map shape for the CLI's `stats`.
  Map<String, Object?> stats();

  /// Release the store's resources.
  void close();
}

/// A repo store and the global store together: what an assembly opens
/// so promotion can move rows between tiers and recall can see both.
/// The pair does NOT merge the databases — each store keeps its file;
/// [recall] and [hottest] interleave both, scoped rows stay scoped.
final class MemoryStorePair {
  MemoryStorePair(this.project, this.global);

  /// The origin-keyed repo database (scope `project`).
  final MemoryStoreApi project;

  /// The machine-global database (scope `global`).
  final MemoryStoreApi global;

  MemoryStoreApi storeFor(MemoryScope scope) =>
      scope == MemoryScope.global ? global : project;

  /// Keyword search across both tiers, project rows first when heat
  /// ties (a repo's own facts outrank generic ones). Heat bumps happen
  /// in whichever store owns the row.
  List<MemoryEntry> recall(String query, {int limit = 20}) {
    final fromProject = project.recall(query, limit: limit);
    final fromGlobal = global.recall(query, limit: limit);
    final merged = [...fromProject, ...fromGlobal];
    merged.sort((a, b) {
      final heat = b.recallCount.compareTo(a.recallCount);
      if (heat != 0) return heat;
      return (b.lastRecalled ?? b.updatedAt)
          .compareTo(a.lastRecalled ?? a.updatedAt);
    });
    return merged.take(limit).toList();
  }

  /// Hottest across both tiers (the hot tier's input).
  List<MemoryEntry> hottest({int limit = 100}) {
    final merged = [...project.hottest(limit: limit), ...global.hottest(limit: limit)];
    merged.sort((a, b) {
      final byCount = b.recallCount.compareTo(a.recallCount);
      if (byCount != 0) return byCount;
      return (b.lastRecalled ?? b.updatedAt)
          .compareTo(a.lastRecalled ?? a.updatedAt);
    });
    return merged.take(limit).toList();
  }

  void close() {
    project.close();
    global.close();
  }
}

/// Normalizes a git remote URL into the origin key: strip protocol
/// schemes, `user@`, `.git` suffix and trailing slashes, lowercase the
/// host — `https://github.com/o/r.git`, `git@github.com:o/r` and
/// `ssh://git@github.com/o/r` all key identically. Empty input is a
/// format error (an origin-less workspace has no repo memory).
String normalizeRepoOrigin(String remote) {
  var value = remote.trim();
  if (value.isEmpty) throw const FormatException('repo origin is empty');
  value = value.replaceFirst(RegExp(r'^[a-z\+]+://'), '');
  final at = value.indexOf('@');
  if (at >= 0 && at < value.indexOf(RegExp(r'[:/]'))) {
    value = value.substring(at + 1);
  }
  value = value.replaceFirst(':', '/');
  if (value.endsWith('.git')) value = value.substring(0, value.length - 4);
  while (value.endsWith('/')) {
    value = value.substring(0, value.length - 1);
  }
  final firstSlash = value.indexOf('/');
  if (firstSlash <= 0 || firstSlash == value.length - 1) {
    throw FormatException('repo origin is not a remote URL: $remote');
  }
  final host = value.substring(0, firstSlash).toLowerCase();
  return '$host${value.substring(firstSlash)}';
}
