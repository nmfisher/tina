/// Persistence for [ApprovalPrecedent]s.
///
/// Deliberately outside the policy's `pureFiles`: this is the only part of the
/// precedent feature that touches the filesystem. The ranking and fast-path
/// predicates stay pure in `precedent.dart`.
library;

import 'dart:convert';
import 'dart:io';

import 'precedent.dart';

/// Storage the mode plugin writes decisions into and reads evidence from.
abstract interface class PrecedentStore {
  /// Every stored precedent. Corrupt lines are skipped, never fatal: a damaged
  /// history must not block approvals.
  List<ApprovalPrecedent> read();

  /// Merge one resolved decision and return the stored record.
  ApprovalPrecedent record({
    required RequestSignature signature,
    required PrecedentOutcome outcome,
    required PrecedentAuthority authority,
    required String coverage,
    DateTime? at,
  });

  void forget(String key);
  void clear();
}

/// In-memory store for tests and for sessions with no persistent location.
final class MemoryPrecedentStore implements PrecedentStore {
  MemoryPrecedentStore([Iterable<ApprovalPrecedent> initial = const []]) {
    for (final precedent in initial) {
      _entries[precedent.key] = precedent;
    }
  }

  /// Mirrors the file store's cap so tests exercise the same bound.
  MemoryPrecedentStore.capped([Iterable<ApprovalPrecedent> initial = const [],
      this.cap = 512]) {
    for (final precedent in initial) {
      _entries[precedent.key] = precedent;
    }
    _evict();
  }

  final _entries = <String, ApprovalPrecedent>{};
  int cap = 512;

  @override
  List<ApprovalPrecedent> read() => List.unmodifiable(_entries.values);

  @override
  ApprovalPrecedent record({
    required RequestSignature signature,
    required PrecedentOutcome outcome,
    required PrecedentAuthority authority,
    required String coverage,
    DateTime? at,
  }) {
    final merged = mergeDecision(
      _entries[signature.key],
      signature: signature,
      outcome: outcome,
      authority: authority,
      at: (at ?? DateTime.now()).toUtc(),
      coverage: coverage,
    );
    _entries[signature.key] = merged;
    _evict();
    return merged;
  }

  @override
  void forget(String key) => _entries.remove(key);

  @override
  void clear() => _entries.clear();

  void _evict() {
    if (_entries.length <= cap) return;
    final ordered = _entries.values.toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    for (final stale in ordered.skip(cap)) {
      _entries.remove(stale.key);
    }
  }
}

/// One workspace's precedents, stored as JSON Lines.
///
/// Writes are atomic (temp file + rename) and the whole file is rewritten on
/// each decision: the record set is small and bounded, and a partial rewrite
/// can never be observed.
final class FilePrecedentStore implements PrecedentStore {
  FilePrecedentStore(this.path, {this.cap = 512});

  final String path;
  final int cap;

  @override
  List<ApprovalPrecedent> read() {
    final file = File(path);
    if (!file.existsSync()) return const [];
    final entries = <String, ApprovalPrecedent>{};
    try {
      for (final line in file.readAsLinesSync()) {
        if (line.trim().isEmpty) continue;
        final precedent = ApprovalPrecedent.fromJson(jsonDecode(line));
        if (precedent != null) entries[precedent.key] = precedent;
      }
    } catch (_) {
      // A truncated or unreadable file yields whatever parsed cleanly. Losing
      // history is recoverable; blocking an approval is not.
      return entries.values.toList();
    }
    return entries.values.toList();
  }

  @override
  ApprovalPrecedent record({
    required RequestSignature signature,
    required PrecedentOutcome outcome,
    required PrecedentAuthority authority,
    required String coverage,
    DateTime? at,
  }) {
    final entries = {for (final entry in read()) entry.key: entry};
    final merged = mergeDecision(
      entries[signature.key],
      signature: signature,
      outcome: outcome,
      authority: authority,
      at: (at ?? DateTime.now()).toUtc(),
      coverage: coverage,
    );
    entries[signature.key] = merged;
    _write(entries.values);
    return merged;
  }

  @override
  void forget(String key) {
    final entries = {for (final entry in read()) entry.key: entry}
      ..remove(key);
    _write(entries.values);
  }

  @override
  void clear() {
    final file = File(path);
    if (file.existsSync()) file.deleteSync();
  }

  void _write(Iterable<ApprovalPrecedent> values) {
    final ordered = values.toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));
    final kept = ordered.take(cap).toList()
      ..sort((a, b) => a.lastSeen.compareTo(b.lastSeen));
    final file = File(path);
    file.parent.createSync(recursive: true);
    final temporary = File('$path.tmp');
    temporary.writeAsStringSync(
      kept.map((entry) => jsonEncode(entry.toJson())).join('\n') +
          (kept.isEmpty ? '' : '\n'),
      flush: true,
    );
    temporary.renameSync(path);
  }
}
