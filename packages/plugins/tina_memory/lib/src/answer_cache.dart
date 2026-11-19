import 'dart:io';

import '../memory_store_api.dart';

/// Precision bar for a cache answer to serve (issue 94: prefer high
/// precision over recall — a wrong answer costs more than a
/// re-search). A candidate serves only when its stored terms cover at
/// least this fraction of the query's terms AND the query covers at
/// least this fraction of the stored terms — symmetric Jaccard-style
/// containment both ways.
const double answerCachePrecision = 0.6;

/// How many stored answers one cache holds (LRU-ish by recency of
/// capture; the oldest fall out).
const int answerCacheCapacity = 50;

/// Result sets beyond this many paths are not captured (issue 94:
/// skip huge result sets).
const int answerCacheMaxPaths = 20;

/// The estimated per-path token cost used for the savings scoreboard
/// (a path plus its separator, conservatively).
const int answerCacheTokensPerPath = 24;

/// Secret shapes that must never be captured: token assignments,
/// key-value credential lines, common credential filenames. Matching
/// is deliberately coarse — redaction prefers false positives.
final RegExp _secretShape = RegExp(
    r'(?:api[_-]?key|token|secret|password|passwd|credential|'
    r'private[_-]?key|BEGIN [A-Z ]*PRIVATE KEY|\.env|\.pem|\.p12|'
    r'id_rsa|id_ed25519|\.aws/credentials|\.netrc|auth\s*[:=])',
    caseSensitive: false);

/// One cached answer: the query terms a future search must echo, the
/// resolved paths that answered it, and when it last served.
final class CachedAnswer {
  CachedAnswer({
    required this.id,
    required this.terms,
    required List<String> paths,
    required DateTime capturedAt,
    this.memoryEntryId,
    this.servedAt,
    this.servedCount = 0,
    this.declinedCount = 0,
  })  : paths = List.of(paths),
        capturedAt = capturedAt;

  final int id;
  final List<String> terms;

  /// The resolved paths — mutable: the freshness gate prunes stale
  /// pointers and recapture refreshes the list.
  List<String> paths;

  /// Recapture refreshes this.
  DateTime capturedAt;

  /// The memory entry this answer is also remembered as (the
  /// injection block cites it so the agent can revise), when capture
  /// chose to mirror into memory.
  final int? memoryEntryId;

  DateTime? servedAt;
  int servedCount;
  int declinedCount;

  /// The paths a serve verified alive (the master [paths] list is
  /// never pruned — a recreated file serves again on the next match;
  /// only an answer with NOTHING alive is dropped).
  List<String>? servedPaths;
}

/// The answer-cache telemetry (the `tina memory stats` scoreboard).
final class AnswerCacheStats {
  const AnswerCacheStats({
    this.captured = 0,
    this.served = 0,
    this.accepted = 0,
    this.declined = 0,
    this.staleDropped = 0,
    this.estimatedTokensSaved = 0,
  });

  final int captured;
  final int served;
  final int accepted;
  final int declined;
  final int staleDropped;
  final int estimatedTokensSaved;

  Map<String, Object?> toMap() => {
        'captured': captured,
        'served': served,
        'accepted': accepted,
        'declined': declined,
        'stale_dropped': staleDropped,
        'estimated_tokens_saved': estimatedTokensSaved,
      };
}

/// The answer cache: captures successful read-only exploratory
/// searches (query terms → resolved paths — pointers, never file
/// contents) and answers later, differently-phrased searches from the
/// cache instead of re-running them.
///
/// Matching is precision-first: symmetric term containment at
/// [answerCachePrecision], verified against the DISK before serving
/// (one stat per path — zero tokens): a stale pointer is dropped and
/// the search proceeds, never a wrong answer.
///
/// Capture-side hygiene (issue 94): secret-shaped queries and paths
/// are redacted by refusal (never stored at all), side-effecting or
/// oversized searches are skipped, and the cache is bounded.
///
/// The store seam: an [AnswerCachePersister] writes answers to the
/// repo's memory store (one `paths` entry per cached answer) so they
/// survive sessions; passing null keeps the cache process-local
/// (tests) — the durable tier is the seam the wasm path will reuse.
final class AnswerCache {
  AnswerCache({
    this.persister,
    AnswerFiles? fileSystem,
    this.precision = answerCachePrecision,
    this.capacity = answerCacheCapacity,
    this.maxPaths = answerCacheMaxPaths,
    this.onCounters,
  }) : fileSystem = fileSystem ?? _RealAnswerFiles.instance;

  /// Receives each counter delta as it happens, so an owner can
  /// persist the scoreboard (the plugin writes it through the memory
  /// store's answer-cache counters). Null keeps the counters
  /// session-only.
  final void Function(AnswerCacheCounters delta)? onCounters;

  void _bump(AnswerCacheCounters delta) => onCounters?.call(delta);

  /// Optional durable mirror into rolling memory (`paths` entries).
  final AnswerCachePersister? persister;

  /// The filesystem seam: the freshness gate stats paths through
  /// this, so tests can simulate deletions without touching disk.
  final AnswerFiles fileSystem;

  final double precision;
  final int capacity;
  final int maxPaths;

  final _answers = <CachedAnswer>[];
  var _nextId = 1;

  int _servedCount = 0;
  int _acceptedCount = 0;
  int _declinedCount = 0;
  int _staleDropped = 0;

  /// Everything currently cached (the CLI's debug view).
  List<CachedAnswer> get answers => List.unmodifiable(_answers);

  /// Telemetry for the scoreboard.
  AnswerCacheStats get stats => AnswerCacheStats(
        captured: _answers.length,
        served: _servedCount,
        accepted: _acceptedCount,
        declined: _declinedCount,
        staleDropped: _staleDropped,
        estimatedTokensSaved: _servedCount * answerCacheTokensPerPath,
      );

  /// Capture one successful read-only search: [query] is the search's
  /// phrasing, [paths] the files it resolved. Refuses (returns null)
  /// when the query or any path looks secret-shaped, when the result
  /// set is too large, or when there is nothing to point at.
  CachedAnswer? capture(String query, List<String> paths) {
    if (paths.isEmpty || paths.length > maxPaths) return null;
    if (_secretShape.hasMatch(query)) return null;
    for (final path in paths) {
      if (_secretShape.hasMatch(path)) return null;
    }
    final terms = _terms(query);
    if (terms.isEmpty) return null;
    // Deduplicate identical recaptures: refresh recency, keep counts.
    for (final answer in _answers) {
      if (_sameTerms(answer.terms, terms)) {
        answer
          ..paths = List.of(paths)
          ..capturedAt = DateTime.now().toUtc();
        return answer;
      }
    }
    final entry = persister?.persist(query, paths);
    final answer = CachedAnswer(
      id: _nextId++,
      terms: terms,
      paths: List.of(paths),
      capturedAt: DateTime.now().toUtc(),
      memoryEntryId: entry?.id,
    );
    _answers.add(answer);
    while (_answers.length > capacity) {
      _answers.removeAt(0);
    }
    return answer;
  }

  /// Match a pending search against the cache. Returns the answer to
  /// serve — with every path verified to still exist — or null when
  /// nothing clears the precision bar or freshness failed.
  ///
  /// [markServed] bumps telemetry; the caller reports back through
  /// [accept]/[decline] once it knows whether the agent used the
  /// answer.
  CachedAnswer? serve(String query) {
    final terms = _terms(query);
    if (terms.isEmpty) return null;
    CachedAnswer? best;
    var bestScore = 0.0;
    for (final answer in _answers) {
      final score = _matchScore(answer.terms, terms);
      if (score >= precision && score > bestScore) {
        best = answer;
        bestScore = score;
      }
    }
    if (best == null) return null;
    // The freshness gate: one stat per path, zero tokens. The
    // MASTER list survives a partial prune — a recreated file serves
    // again on the next match — but an answer with nothing alive is
    // removed entirely and the search proceeds. Never a wrong answer.
    final alive = [
      for (final path in best.paths)
        if (fileSystem.exists(path)) path
    ];
    if (alive.isEmpty) {
      _staleDropped += best.paths.length;
      _bump(AnswerCacheCounters(staleDropped: best.paths.length));
      _answers.remove(best);
      return null;
    }
    _staleDropped += best.paths.length - alive.length;
    best.servedPaths = alive;
    best.servedAt = DateTime.now().toUtc();
    best.servedCount++;
    _servedCount++;
    _bump(AnswerCacheCounters(
        served: 1,
        staleDropped: best.paths.length - alive.length,
        tokensSaved: answerCacheTokensPerPath));
    return best;
  }

  /// The agent used the served answer (skipped the search).
  void accept(CachedAnswer answer) {
    _acceptedCount++;
    _bump(const AnswerCacheCounters(accepted: 1));
  }

  /// The agent re-searched anyway after being served.
  void decline(CachedAnswer answer) {
    _declinedCount++;
    _bump(const AnswerCacheCounters(declined: 1));
  }

  /// Renders the injection block for a served answer: labeled, with
  /// entry ids, paths, ages and the revise-instead-of-re-search rule.
  String injectionBlock(CachedAnswer answer) {
    final ageDays =
        DateTime.now().difference(answer.capturedAt).inDays;
    final memory = answer.memoryEntryId == null
        ? ''
        : ' (memory entry #${answer.memoryEntryId})';
    return '<memory-answer-cache>This search was answered from rolling '
        'memory (captured $ageDays d ago$memory). Paths:\n'
        '${(answer.servedPaths ?? answer.paths).map((p) => '  $p').join('\n')}\n'
        'If this is stale or wrong, revise or forget the memory entry '
        'instead of re-searching.</memory-answer-cache>';
  }

  /// Content words only: stop words carry no search intent, and
  /// keeping them would make differently-phrased queries look
  /// dissimilar (the matching is over these terms).
  static const _stopWords = {
        'the', 'a', 'an', 'is', 'are', 'was', 'were', 'be', 'been',
        'of', 'in', 'on', 'at', 'to', 'for', 'with', 'by', 'from',
        'find', 'where', 'what', 'which', 'how', 'please', 'show',
        'me', 'list', 'all', 'any', 'and', 'or', 'not', 'do', 'does',
        'did', 'can', 'could', 'should', 'would', 'will', 'just',
        'file', 'files', 'location', 'locations',
      };

  static List<String> _terms(String query) => [
        for (final match in RegExp(r'[A-Za-z0-9_./-]+').allMatches(query))
          match.group(0)!.toLowerCase()
      ].where((t) => !_stopWords.contains(t)).toSet().toList();

  static bool _sameTerms(List<String> a, List<String> b) =>
      a.length == b.length && a.toSet().containsAll(b);

  /// Symmetric containment: the fraction of stored terms present in
  /// the query TIMES the fraction of query terms present in the
  /// stored set — both directions must clear [precision] for the
  /// product to clear it. Terms match exactly OR by a shared prefix
  /// of at least 4 characters (a deliberately crude stem: 'build'
  /// matches 'builder'), which is what lets a differently-PHRASED
  /// query resolve while unrelated words still fail the bar.
  static double _matchScore(List<String> stored, List<String> query) {
    if (stored.isEmpty || query.isEmpty) return 0;
    final coveredStored =
        stored.where((s) => query.any((q) => _termMatch(s, q))).length /
            stored.length;
    final coveredQuery =
        query.where((q) => stored.any((s) => _termMatch(s, q))).length /
            query.length;
    return coveredStored * coveredQuery;
  }

  static bool _termMatch(String a, String b) {
    if (a == b) return true;
    final shorter = a.length < b.length ? a : b;
    if (shorter.length < 4) return false;
    return a.startsWith(b) || b.startsWith(a);
  }
}

/// The durability seam: mirror cached answers into the repo's rolling
/// memory so they survive sessions. The default persister writes one
/// `paths` entry per answer (pointers, redaction already applied by
/// capture).
final class MemoryAnswerPersister implements AnswerCachePersister {
  MemoryAnswerPersister(this._store);

  final MemoryStoreApi _store;

  @override
  MemoryEntry? persist(String query, List<String> paths) {
    if (_secretShape.hasMatch(query)) return null;
    return _store.remember(
        'search "$query" resolves to: ${paths.join(', ')}',
        category: MemoryCategory.paths,
        updatedBy: 'answer-cache');
  }
}

abstract interface class AnswerCachePersister {
  MemoryEntry? persist(String query, List<String> paths);
}

/// The filesystem seam for the freshness gate.
abstract interface class AnswerFiles {
  bool exists(String path);
}

final class _RealAnswerFiles implements AnswerFiles {
  static final instance = _RealAnswerFiles();
  @override
  bool exists(String path) => File(path).existsSync();
}
