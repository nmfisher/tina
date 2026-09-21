import 'dart:async';
import 'dart:collection';

import '../judgments/service.dart' show JudgmentCancellation;
import '../shared/fingerprint.dart';
import '../shared/range_packer.dart';
import 'definitions.dart';
import 'evidence.dart';
import 'models.dart';
import 'planning.dart';
import 'store.dart';

part 'tree.dart';

class ClassificationTask<I, O> {
  final String key;
  final SourceRequest request;
  final ClassificationSource<I> source;
  final ClassificationPlan<I, O> plan;
  final Map<String, Object?> upstream;
  ClassificationTask({
    required this.key,
    required this.request,
    required this.source,
    required this.plan,
    Map<String, Object?> upstream = const {},
  }) : upstream = freezeJson(upstream) as Map<String, Object?> {
    if (key.isEmpty ||
        contractFingerprint(source.contract) !=
            contractFingerprint(plan.input)) {
      throw ArgumentError(
        'Invalid task key or incompatible source/input contract',
      );
    }
  }
}

/// A typed dependency graph for one output family. Different output families
/// can be scheduled in successive graphs in the same session (e.g. discovery
/// returning entities, then independent classification jobs for those entities).
class ClassificationNode<I, O> {
  final String key;
  final List<String> requires;
  final ClassificationTask<I, O> Function(Map<String, ClassificationRecord<O>>)
  build;
  ClassificationNode(
    this.key, {
    Iterable<String> requires = const [],
    required this.build,
  }) : requires = List.unmodifiable(requires);
}

class ClassificationReport<O> {
  final Map<String, ClassificationRecord<O>> records;
  final Map<String, String> failures;
  ClassificationReport(
    Map<String, ClassificationRecord<O>> records,
    Map<String, String> failures,
  ) : records = Map.unmodifiable(records),
      failures = Map.unmodifiable(failures);
}

/// Store/agent lifecycle for a group of arbitrary typed classification tasks.
/// No source domain, discovery phase, label vocabulary, or hierarchy is assumed.
class ClassificationOrchestrator {
  final ClassificationStore store;
  final ClassificationExecutor executor;
  final ClassificationBudget budget;
  final int concurrency;
  final int maxCalls;
  final Duration timeout;
  bool _running = false;
  ClassificationOrchestrator({
    required this.store,
    required this.executor,
    ClassificationBudget? budget,
    this.concurrency = 3,
    this.maxCalls = 128,
    this.timeout = const Duration(minutes: 5),
  }) : budget = budget ?? ClassificationBudget() {
    if (concurrency < 1 || maxCalls < 1 || timeout <= Duration.zero)
      throw ArgumentError('Invalid classification limits');
  }
  Future<T> run<T>(
    Future<T> Function(ClassificationSession session) work, {
    bool refresh = false,
    bool restoreOnly = false,
    JudgmentCancellation? cancellation,
    void Function(String)? onProgress,
  }) async {
    if (_running) throw StateError('Classification already running');
    _running = true;
    final stop = JudgmentCancellation();
    final detach = cancellation?.listen(stop.cancel);
    final timer = Timer(timeout, stop.cancel);
    ClassificationSession? session;
    try {
      Future<T> execute() async {
        final saved = await store.readManifest();
        final manifest = <String, String>{};
        if (saved?['schema_version'] == classificationSchemaVersion) {
          try {
            manifest.addAll(Map<String, String>.from(saved!['records'] as Map));
          } catch (_) {}
        }
        session = ClassificationSession._(
          this,
          manifest,
          stop,
          refresh,
          restoreOnly,
          onProgress,
        );
        return work(session!);
      }

      return restoreOnly ? await execute() : await store.withWriter(execute);
    } finally {
      stop.cancel(); // No late adapter may publish after the writer scope ends.
      await session?._checkpoint;
      timer.cancel();
      detach?.call();
      _running = false;
    }
  }
}

class ClassificationSession {
  final ClassificationOrchestrator _owner;
  final Map<String, String> _manifest;
  final JudgmentCancellation cancellation;
  final bool refresh;
  final bool restoreOnly;
  final void Function(String)? _progress;
  int executed = 0;
  int restored = 0;
  int reusedRequests = 0;
  Future<void> _checkpoint = Future.value();
  final _activeKeys = <String>{};
  int _inFlight = 0;
  final _waiting = Queue<Completer<void>>();
  ClassificationSession._(
    this._owner,
    this._manifest,
    this.cancellation,
    this.refresh,
    this.restoreOnly,
    this._progress,
  );

  void _check() {
    if (cancellation.isCancelled) throw StateError('Classification cancelled');
  }

  Future<T> _bounded<T>(Future<T> Function() work) async {
    _check();
    final stopped = Completer<T>();
    final detach = cancellation.listen(
      () => stopped.completeError(StateError('Classification cancelled')),
    );
    try {
      return await Future.any([Future.sync(work), stopped.future]);
    } finally {
      detach();
    }
  }

  Future<T> _withSlot<T>(Future<T> Function() work) async {
    while (_inFlight >= _owner.concurrency) {
      final waiter = Completer<void>();
      _waiting.add(waiter);
      await _bounded(() => waiter.future);
    }
    _check();
    _inFlight++;
    try {
      return await work();
    } finally {
      _inFlight--;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }

  Future<ClassificationRecord<O>> classify<I, O>(
    ClassificationTask<I, O> task,
  ) async {
    _check();
    if (!_activeKeys.add(task.key))
      throw StateError('Duplicate active classification key');
    try {
      final provenance = <String, Object?>{
        'request': task.request.toJson(),
        'source': task.source.identity,
        'input': task.source.contract.identity,
        'splitter': task.source.splitter?.identity,
        'plan': task.plan.identity,
        'executor': _owner.executor.configuration,
        'budget': _owner.budget.identity,
        'upstream': task.upstream,
      };
      final signature = canonicalFingerprint(provenance);
      final manifestKey = 'task:${task.key}';
      if (!refresh) {
        final saved = await _load(manifestKey);
        if (saved != null && saved['signature'] == signature) {
          try {
            final revision = SourceRevision(
              jsonObject(saved['source_revision']),
            );
            if (await _bounded(
              () => task.source.isCurrent(revision, cancellation),
            )) {
              final result = ClassificationResult.fromJson(
                saved['result'],
                task.plan.output,
              );
              final coverage = InputCoverage.fromJson(saved['coverage']);
              final record = ClassificationRecord(
                _manifest[manifestKey]!,
                result,
                coverage,
                task.plan.output,
              );
              restored++;
              _progress?.call('Restored ${task.key}');
              return record;
            }
          } catch (_) {
            _check();
          }
        }
      }
      if (restoreOnly) throw StateError('Missing or stale classification');
      _progress?.call('Classifying ${task.key}');
      final snapshot = await _bounded(
        () => task.source.snapshot(task.request, cancellation),
      );
      if (canonicalFingerprint(snapshot.splitter?.identity) !=
          canonicalFingerprint(task.source.splitter?.identity)) {
        throw StateError('Snapshot/source splitting policies disagree');
      }
      final dispatcher = _TaskDispatcher(
        this,
        task.source.identity,
        snapshot.splitter?.identity,
      );
      final result = await task.plan.run(snapshot, task.upstream, dispatcher);
      _check();
      if (result.outcome == ClassificationOutcome.notApplicable &&
          !snapshot.coverage.complete) {
        throw StateError(
          'Incomplete input cannot establish a complete negative classification',
        );
      }
      if (!await _bounded(
        () => task.source.isCurrent(snapshot.revision, cancellation),
      )) {
        throw StateError('Source changed during classification');
      }
      final json = <String, Object?>{
        'schema_version': classificationSchemaVersion,
        'signature': signature,
        'provenance': provenance,
        'source_revision': snapshot.revision.receipt,
        'coverage': snapshot.coverage.toJson(),
        'request_records': dispatcher.recordIds,
        'result': result.toJson(task.plan.output),
      };
      final id = await _publish(manifestKey, json);
      return ClassificationRecord(
        id,
        result,
        snapshot.coverage,
        task.plan.output,
      );
    } finally {
      _activeKeys.remove(task.key);
    }
  }

  Future<Map<String, dynamic>?> _load(String key) async {
    final id = _manifest[key];
    if (id == null) return null;
    try {
      final record = await _owner.store.readRecord(id);
      if (record == null ||
          record['schema_version'] != classificationSchemaVersion ||
          canonicalFingerprint(record) != id)
        return null;
      return record;
    } catch (_) {
      return null;
    }
  }

  Future<String> _publish(String key, Map<String, Object?> record) async {
    final id = canonicalFingerprint(record);
    final write = _checkpoint.then((_) async {
      _check();
      await _owner.store.writeRecord(id, record);
      // Only mutate the in-memory manifest after the corresponding publication succeeds.
      final next = {..._manifest, key: id};
      await _owner.store.writeManifest({
        'schema_version': classificationSchemaVersion,
        'records': next,
      });
      _manifest
        ..clear()
        ..addAll(next);
    });
    _checkpoint = write.catchError((Object _) {});
    await write;
    return id;
  }

  Future<ClassificationReport<O>> runGraph<I, O>(
    List<ClassificationNode<I, O>> nodes,
  ) async {
    final ids = nodes.map((n) => n.key).toSet();
    if (ids.length != nodes.length ||
        nodes.any((n) => n.requires.any((k) => !ids.contains(k)))) {
      throw ArgumentError('Duplicate graph key or missing prerequisite');
    }
    final pending = List.of(nodes);
    final done = <String>{};
    final levels = <List<ClassificationNode<I, O>>>[];
    while (pending.isNotEmpty) {
      final level = pending
          .where((n) => n.requires.every(done.contains))
          .toList();
      if (level.isEmpty) throw ArgumentError('Classification dependency cycle');
      levels.add(level);
      done.addAll(level.map((n) => n.key));
      pending.removeWhere(level.contains);
    }
    final records = <String, ClassificationRecord<O>>{};
    final failures = <String, String>{};
    for (final level in levels) {
      var next = 0;
      Future<void> worker() async {
        while (next < level.length) {
          final node = level[next++];
          final missing = node.requires.where((k) => !records.containsKey(k));
          if (missing.isNotEmpty) {
            failures[node.key] = 'Blocked by ${missing.join(', ')}';
            continue;
          }
          try {
            final dependencies = {
              for (final k in node.requires) k: records[k]!,
            };
            final task = node.build(Map.unmodifiable(dependencies));
            if (task.key != node.key)
              throw StateError('Graph node/task key mismatch');
            // Dependencies are injected by the scheduler, never left to a caller
            // to remember when constructing a cache identity.
            records[node.key] = await classify(
              ClassificationTask(
                key: task.key,
                request: task.request,
                source: task.source,
                plan: task.plan,
                upstream: {
                  ...task.upstream,
                  for (final e in dependencies.entries)
                    e.key: e.value.dependency,
                },
              ),
            );
          } catch (e) {
            failures[node.key] = cancellation.isCancelled ? 'Cancelled' : '$e';
          }
        }
      }

      await Future.wait([
        for (var i = 0; i < _owner.concurrency && i < level.length; i++)
          worker(),
      ]);
    }
    return ClassificationReport(records, failures);
  }

  /// Application discovery can remove obsolete subjects without touching the
  /// generic request checkpoints used by interrupted or overlapping jobs.
  Future<void> retainTasks(Set<String> keys) async {
    if (restoreOnly) return;
    _check();
    final write = _checkpoint.then((_) async {
      _check();
      final next = Map<String, String>.of(_manifest)
        ..removeWhere(
          (key, _) =>
              key.startsWith('task:') && !keys.contains(key.substring(5)),
        );
      await _owner.store.writeManifest({
        'schema_version': classificationSchemaVersion,
        'records': next,
      });
      _manifest
        ..clear()
        ..addAll(next);
    });
    _checkpoint = write.catchError((Object _) {});
    await write;
  }
}

class _TaskDispatcher implements ClassificationDispatcher {
  final ClassificationSession session;
  final Object sourceIdentity;
  final Object? splitterIdentity;
  final recordIds = <String>[];
  _TaskDispatcher(this.session, this.sourceIdentity, this.splitterIdentity);
  @override
  ClassificationBudget get budget => session._owner.budget;
  @override
  bool fits<I, O>(ClassificationRequest<I, O> request) {
    final estimate = session._owner.executor.estimate(request);
    if (estimate < 0) throw StateError('Negative request estimate');
    return estimate <= budget.inputLimit;
  }

  @override
  Future<ClassificationResult<O>> dispatch<I, O>(
    ClassificationRequest<I, O> request,
  ) async {
    session._check();
    if (!fits(request)) throw const InputTooLargeException();
    final identity = <String, Object?>{
      'request': canonicalFingerprint(request.toJson()),
      'definition': request.definition.identity,
      'source': sourceIdentity,
      'splitter': splitterIdentity,
      'evidence_units': [
        for (final unit in request.input.units)
          {
            'id': unit.id,
            'location': unit.location,
            'supporting_evidence': unit.supportingEvidence,
          },
      ],
      'executor': session._owner.executor.configuration,
      'budget': budget.identity,
    };
    final signature = canonicalFingerprint(identity);
    final key = 'request:$signature';
    if (!session.refresh) {
      final saved = await session._load(key);
      if (saved != null && saved['signature'] == signature) {
        try {
          final result = ClassificationResult.fromJson(
            saved['result'],
            request.definition.output,
          );
          request.validate(result);
          session.reusedRequests++;
          recordIds.add(session._manifest[key]!);
          return result;
        } catch (_) {}
      }
    }
    final result = await session._withSlot(() async {
      if (session.executed >= session._owner.maxCalls)
        throw StateError('Classification request limit reached');
      session.executed++;
      return session._bounded(
        () => session._owner.executor.execute(
          request,
          session.cancellation,
          maxInputTokens: budget.inputLimit,
          maxOutputTokens: budget.outputTokens,
        ),
      );
    });
    request.validate(result);
    final id = await session._publish(key, {
      'schema_version': classificationSchemaVersion,
      'signature': signature,
      'provenance': identity,
      'result': result.toJson(request.definition.output),
    });
    recordIds.add(id);
    return result;
  }
}
