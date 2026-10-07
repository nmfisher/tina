/// Speculative execution for read-only tools.
///
/// The classifier predicts which read-only calls the model is about to make
/// (ls/glob/stat/read), runs them **outside** the loop while the main model
/// is still thinking, and the real executor seam serves the cached result
/// when the model's call arrives. Predictions never execute mutations and
/// never enter the prompt or the log. Results are snapshots taken earlier;
/// external filesystem changes are not tracked. Plugin wiring is opt-in.
///
/// Staleness is bounded by construction, not by timestamps:
///
/// - only the read-only tools' executors are wrapped for consumption;
/// - every mutating executor (write, edit, bash, exec, process) clears the
///   cache after it runs, on success and on failure;
/// - the cache also clears at turn end, so a hit can only be as stale as
///   "since the user pressed enter";
/// - a prefetch batch that races a clear drops its in-flight results
///   (generation check) instead of landing them after the invalidation.
///
/// Errors are snapshots too (a missing file can appear later). Sandbox
/// authorization is rechecked when consuming a prediction, and external
/// writers are not tracked. This is an experimental opt-in seam, not a
/// freshness guarantee or an active classifier integration.
library;

import 'dart:collection';
import 'dart:convert';

import 'package:tina_core/tina_core.dart';

/// A result stored under a canonical call identity.
final class _Entry {
  _Entry(this.result);
  final ToolResult result;
  int hits = 0;
}

/// Immutable counter snapshot for diagnostics and hit-rate measurement.
final class SpeculativeStats {
  const SpeculativeStats({
    required this.hits,
    required this.misses,
    required this.stored,
    required this.prefetched,
    required this.evictions,
    required this.entries,
  });
  final int hits;
  final int misses;
  final int stored;
  final int prefetched;
  final int evictions;
  final int entries;

  @override
  String toString() => 'hits=$hits misses=$misses stored=$stored '
      'prefetched=$prefetched evictions=$evictions entries=$entries';
}

/// A bounded, canonical-keyed cache of read-only tool results.
///
/// The key is the tool name plus the input map in canonical form (nested
/// maps sorted by key, argument defaults filled in, path values in one
/// spelling), so `{"path": "lib"}` and `{"path": "./lib/"}` are the same
/// call. The [defaults] per tool make an omitted argument and an explicit
/// default collide; they are passed at the wiring site, next to the tool
/// whose defaults they mirror.
final class SpeculativeCache {
  SpeculativeCache({
    this.defaults = const {},
    this.maxEntries = 32,
    this.maxResultLength = 64 * 1024,
  })  : assert(maxEntries > 0),
        assert(maxResultLength > 0);

  /// Per-tool argument defaults, e.g. `{'ls': {'maxResults': 200}}`. A key
  /// absent from an input is canonicalized as if it held the default, so a
  /// prefetched call with explicit arguments serves the model's omitted
  /// ones. Keep in sync with the wrapped tools' documented defaults.
  final Map<String, Map<String, Object?>> defaults;

  /// Oldest entries fall out beyond this bound; a read-only listing is
  /// small, so count is the honest limit.
  final int maxEntries;

  /// Results longer than this are never stored (a `read` of a huge file,
  /// for instance), they just run normally every time.
  final int maxResultLength;

  final LinkedHashMap<String, _Entry> _entries = LinkedHashMap();
  final _MutableStats _stats = _MutableStats();
  int _generation = 0;
  int _mutations = 0;

  bool get canCache => _mutations == 0;

  void beginMutation() {
    _mutations++;
    clear();
  }

  void endMutation() {
    _mutations--;
    clear();
  }

  /// Bumped by every [clear]; a prefetch batch validates its captured
  /// generation before storing, so an invalidated run cannot land results.
  int get generation => _generation;

  SpeculativeStats get stats => _stats.snapshot(_entries.length);

  /// The canonical key for one tool call, or null when the input cannot be
  /// canonicalized (non-JSON-safe values). Null means never cache.
  String? keyOf(String tool, Map<String, Object?> input) {
    final canonical = _canonicalize(tool, input);
    if (canonical == null) return null;
    return '$tool:${jsonEncode(canonical)}';
  }

  /// The stored result for this exact call, if any. Refreshes recency.
  ToolResult? get(String tool, Map<String, Object?> input) {
    final key = keyOf(tool, input);
    if (key == null) return null;
    final entry = _entries.remove(key);
    if (entry == null) {
      _stats.misses++;
      return null;
    }
    _entries[key] = entry; // re-insert at the recency end
    entry.hits++;
    _stats.hits++;
    return entry.result;
  }

  /// Like [get], without touching recency or counters. The prefetch uses
  /// this to skip already-cached calls without stealing the consumer's hit.
  ToolResult? peek(String tool, Map<String, Object?> input) {
    final key = keyOf(tool, input);
    if (key == null) return null;
    return _entries[key]?.result;
  }

  /// Store a result under this call's identity. Oversized and
  /// non-canonicalizable calls are silently not stored — they run normally.
  void put(
    String tool,
    Map<String, Object?> input,
    ToolResult result, {
    bool speculative = false,
  }) {
    if (!canCache || result.content.length > maxResultLength) return;
    final key = keyOf(tool, input);
    if (key == null) return;
    final existing = _entries.remove(key);
    if (existing != null) _stats.evictions++;
    _entries[key] = _Entry(result);
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
      _stats.evictions++;
    }
    if (speculative) {
      _stats.prefetched++;
    } else {
      _stats.stored++;
    }
  }

  /// Drop everything; mutating executors and turn end call this. Any
  /// prefetch batch in flight is invalidated via [generation].
  void clear() {
    if (_entries.isNotEmpty) _stats.evictions += _entries.length;
    _entries.clear();
    _generation++;
  }

  /// Wrap a read-only executor for a dispatch seam: a cache hit
  /// returns immediately, a miss runs [inner] and is stored for next time.
  /// [validate] rechecks the filesystem boundary before a cached result can
  /// be served. Plugin wiring consumes predictions once and does not store
  /// ordinary reads; standalone callers can choose memoization explicitly.
  Future<ToolResult> Function(Map<String, Object?>) wrap(
    String tool,
    Future<ToolResult> Function(Map<String, Object?>) inner, {
    Future<ToolResult?> Function(Map<String, Object?>)? validate,
    bool storeMisses = true,
    bool consume = false,
  }) =>
      (input) async {
        final generation = _generation;
        final refusal = await validate?.call(input);
        if (refusal != null) return refusal;
        final hit =
            canCache && generation == _generation ? get(tool, input) : null;
        if (hit != null && consume) _entries.remove(keyOf(tool, input));
        if (hit != null) return hit;
        final result = await inner(input);
        if (storeMisses && generation == _generation) put(tool, input, result);
        return result;
      };

  /// Canonical structure for [input]: a JSON-safe tree with sorted map
  /// keys, per-tool defaults filled in, and path-valued keys normalized to
  /// one spelling. Null when a value cannot be canonicalized.
  Object? _canonicalize(String tool, Map<String, Object?> input) {
    final filled = {
      ...?defaults[tool],
      for (final e in input.entries) e.key: e.value,
    };
    final pathField = switch (tool) {
      'read' => 'filePath',
      'ls' || 'glob' || 'stat' => 'path',
      _ => null,
    };
    if (pathField != null && filled[pathField] is String) {
      filled[pathField] = _canonicalString(filled[pathField] as String);
    }
    return _canonicalValue(filled);
  }

  Object? _canonicalValue(Object? value) {
    if (value is Map) {
      final sorted = SplayTreeMap<String, Object?>();
      for (final e in value.entries) {
        final canonical = _canonicalValue(e.value);
        if (canonical == null && e.value != null) return null;
        final key = e.key;
        if (key is! String) return null;
        sorted[key] = canonical;
      }
      return sorted;
    }
    if (value is List) {
      final items = <Object?>[];
      for (final item in value) {
        final canonical = _canonicalValue(item);
        if (canonical == null && item != null) return null;
        items.add(canonical);
      }
      return items;
    }
    if (value is String) return value;
    if (value is num && !value.isFinite) return null;
    if (value == null || value is bool || value is num) return value;
    return null; // not JSON-safe: never canonicalize
  }

  /// One spelling per path: collapse separator runs, drop a leading `./`,
  /// drop trailing separators — unless the whole value is a root. Only
  /// known top-level path fields are normalized; patterns stay literal.
  static String _canonicalString(String value) {
    if (value.isEmpty) return value;
    var v = value.replaceAll(RegExp(r'/+'), '/');
    while (v.startsWith('./')) {
      v = v.substring(2);
    }
    if (v.length > 1 && v.endsWith('/')) v = v.substring(0, v.length - 1);
    return v.isEmpty ? '.' : v;
  }
}

class _MutableStats {
  int hits = 0, misses = 0, stored = 0, prefetched = 0, evictions = 0;
  SpeculativeStats snapshot(int entries) => SpeculativeStats(
        hits: hits,
        misses: misses,
        stored: stored,
        prefetched: prefetched,
        evictions: evictions,
        entries: entries,
      );
}

/// The names whose executors may be speculatively executed. Everything else
/// — every mutating or stateful tool — is a cache **clearer**, never a
/// cached call.
const speculativeTools = {'ls', 'glob', 'stat', 'read'};

/// The names whose execution invalidates the cache: they can change the
/// very files the read-only tools describe.
const speculativeInvalidatingTools = {
  'write',
  'edit',
  'bash',
  'exec',
  'process',
};

/// Runs predicted read-only calls into a [SpeculativeCache] while the main
/// model is still producing its turn. Candidates come from the prediction
/// stage; this class owns the discipline:
///
/// - one live batch at a time — a new [submit] supersedes the previous one;
/// - calls already in the cache are skipped, not re-executed;
/// - results land only if no [SpeculativeCache.clear] happened meanwhile
///   (generation check), and never for oversized outputs (cache's rule);
/// - cancellation between items stops the batch promptly.
final class SpeculativePrefetch {
  SpeculativePrefetch(this._cache, this._executors, {bool Function()? enabled})
      : _enabled = enabled ?? (() => true);

  final bool Function() _enabled;

  void cancel() => _batch++;

  final SpeculativeCache _cache;

  /// Exactly the read-only tools' plain executors, keyed by tool name.
  /// Mutating tools must not appear here; the allowlist filters anyway.
  final Map<String, Future<ToolResult> Function(Map<String, Object?>)>
      _executors;

  int _batch = 0;
  int _running = 0;

  /// How many executions of the current batch are still in flight.
  int get pending => _running;

  /// Submit predicted calls. Returns when the whole batch has settled
  /// (executed, skipped, or dropped). Supersedes any earlier batch.
  ///
  /// [untilCancelled] completes when the enclosing turn is cancelled; the
  /// batch stops between items when it has fired. When null the batch runs
  /// to completion — submit is only called with a live turn's token.
  Future<void> submit(
    List<(String, Map<String, Object?>)> calls, {
    Future<void>? untilCancelled,
  }) async {
    final mine = ++_batch;
    final generation = _cache.generation;
    Future<bool> cancelled() async => untilCancelled == null
        ? false
        : await untilCancelled
            .then<bool>((_) => true)
            .timeout(Duration.zero, onTimeout: () => false);
    final seen = <String>{};
    for (final (tool, input) in calls) {
      if (!_enabled() ||
          !_cache.canCache ||
          mine != _batch ||
          generation != _cache.generation) return;
      if (untilCancelled != null) {
        // Zero-timeout probe: false only when the token is still pending,
        // so a never-completing token never blocks the next item.
        final cancelled = await untilCancelled
            .then<bool>((_) => true)
            .timeout(Duration.zero, onTimeout: () => false);
        if (cancelled) return;
      }
      final key = _cache.keyOf(tool, input);
      if (key == null || !seen.add(key)) continue;
      if (_cache.peek(tool, input) != null) continue; // already cached
      final exec = _executors[tool];
      if (exec == null || !speculativeTools.contains(tool)) continue;
      _running++;
      try {
        final result = await exec(input);
        // A clear while this ran (a real mutation, a new turn) outranks
        // the prefetch: drop instead of landing stale state.
        if (!await cancelled() &&
            _enabled() &&
            mine == _batch &&
            _cache.generation == generation) {
          _cache.put(tool, input, result, speculative: true);
        }
      } catch (_) {
        // A throwing speculative executor is indistinguishable from a tool
        // that will throw for the model later; the miss just re-runs.
      } finally {
        _running--;
      }
    }
  }
}
