import 'dart:async';
import 'dart:convert';
import 'dart:collection';
import '../judgments/batch_runner.dart'
    show JudgmentBatchLimits, JudgmentBatchRunner;
import '../judgments/service.dart'
    show JudgmentCancellation, JudgmentException, JudgmentFailure;
import 'models.dart';
import 'repository_ranker.dart';
import 'file_chunker.dart';
import 'exploration_cache.dart';
import 'exploration_snapshot.dart';

/// Repository filtering, not an autonomous scout. Metadata ranks all files;
/// selective content rounds stop once useful evidence can be handed off.
class ExplorationWorkflow {
  final ProjectEvidenceSource source;
  final JudgmentBatchRunner runner;
  final Duration timeout;
  final RepositoryRanker ranker;
  final double selectionThreshold;
  final double matchThreshold;
  final int maxReadBytes;
  final ExplorationCache? cache;
  final String cacheEndpoint;
  ExplorationWorkflow({
    required this.source,
    required this.runner,
    this.cache,
    this.cacheEndpoint = 'https://api.typesafe.ai/v1/systemone',
    this.timeout = const Duration(minutes: 2),
    JudgmentBatchRunner? metadataRunner,
    this.selectionThreshold = 0.9,
    this.matchThreshold = 0.8,
    this.maxReadBytes = 8 * 1024 * 1024,
  }) : ranker = RepositoryRanker(
         metadataRunner ??
             JudgmentBatchRunner(
               service: runner.service,
               budget: runner.budget,
               limits: JudgmentBatchLimits(
                 concurrency: runner.limits.concurrency,
                 maxRequests: runner.limits.maxRequests,
                 maxChargedTokens: 60000,
                 outputTokenAllowance: runner.limits.outputTokenAllowance,
                 requestTimeout: runner.limits.requestTimeout,
                 timeout: timeout,
               ),
             ),
       ) {
    if (timeout <= Duration.zero ||
        maxReadBytes <= 0 ||
        !selectionThreshold.isFinite ||
        selectionThreshold < 0 ||
        selectionThreshold > 1 ||
        !matchThreshold.isFinite ||
        matchThreshold < 0 ||
        matchThreshold > 1) {
      throw ArgumentError('Invalid exploration limits');
    }
  }

  Future<ExplorationResult> run(
    String question, {
    JudgmentCancellation? cancellation,
    void Function(String)? onProgress,
    ExplorationMode mode = ExplorationMode.auto,
    int maxResults = 1,
    bool refresh = false,
  }) async {
    if (question.trim().isEmpty ||
        question.length > 2000 ||
        maxResults < 1 ||
        maxResults > 8) {
      throw const JudgmentException(JudgmentFailure.invalidRequest);
    }
    final stop = JudgmentCancellation();
    var timedOut = false;
    var finished = false;
    final detach = cancellation?.listen(stop.cancel);
    final timer = Timer(timeout, () {
      timedOut = true;
      stop.cancel();
    });
    final watch = Stopwatch()..start();
    void progress(String line) {
      if (!finished) onProgress?.call(line);
    }

    final session = ExplorationCacheSession(
      store: cache,
      endpoint: cacheEndpoint,
      cancellation: stop,
      refresh: refresh,
    );
    try {
      final tree = await _untilCancelled(
        source.enumerate(stop, progress),
        stop,
        ProjectTree([], ['Enumeration interrupted.']),
      );
      final manifestHash = explorationFingerprint({
        'paths': tree.paths,
        'gaps': tree.gaps,
      });
      final answerKey = session.key('answer', {
        'revision': explorationCacheRevision,
        'ranking_model': ranker.runner.budget.model,
        'content_model': runner.budget.model,
        'question': question,
        'manifest': manifestHash,
        'mode': mode.name,
        'max_results': maxResults,
        'selection': selectionThreshold,
        'match': matchThreshold,
      });
      EvidenceScan? validationScan;
      final saved = await session.get(answerKey);
      if (saved != null && !stop.isCancelled) {
        try {
          final dependencies = Map<String, String>.from(
            saved['dependencies'] as Map,
          );
          if (dependencies.keys.any((p) => !tree.paths.contains(p)))
            throw const FormatException('Unknown dependency');
          final checkedScan = dependencies.isEmpty
              ? EvidenceScan([], 0, [], bytesRead: 0)
              : await _untilCancelled(
                  source.read(
                    dependencies.keys.toList(),
                    stop,
                    progress,
                    maxBytes: maxReadBytes,
                  ),
                  stop,
                  EvidenceScan([], 0, []),
                );
          validationScan = checkedScan;
          final evidence = {for (final f in checkedScan.evidence) f.path: f};
          if (!stop.isCancelled &&
              dependencies.entries.every(
                (e) =>
                    evidence[e.key] != null &&
                    evidenceHash(evidence[e.key]!.text) == e.value,
              )) {
            final answer = decodeExplorationSnapshot(
              Map<String, dynamic>.from(saved['result'] as Map),
              expectedPaths: tree.paths.toSet(),
              dependencies: dependencies.keys.toSet(),
              filesScanned: checkedScan.filesScanned,
              elapsedMs: watch.elapsedMilliseconds,
            );
            progress(
              'Exploring: reused cached answer; validated ${dependencies.length} file hashes, no API calls',
            );
            return answer;
          }
        } catch (_) {
          /* Corrupt/stale snapshots fall back to per-request reuse. */
        }
      }
      final ranking = await ranker.run(
        tree,
        question,
        stop,
        progress,
        cache: session,
      );
      final candidates = ranking.candidates;
      final gaps = [...tree.gaps];
      if (!ranking.complete)
        gaps.add('Some file names were not ranked; see ranking failures.');
      final loaded = <String, _PendingFile>{};
      final chunker = FileChunker(runner.budget);
      final prefetched = {
        for (final f in validationScan?.evidence ?? <ProjectEvidence>[])
          f.path: f,
      };
      var readBytes =
          validationScan?.bytesRead ??
          prefetched.values.fold<int>(
            0,
            (sum, f) => sum + utf8.encode(f.text).length,
          );
      var scanned = validationScan?.filesScanned ?? 0;
      var contentCharge = 0;
      var contentRequests = 0;
      var contentCacheHits = 0;
      var matches = 0;
      int? firstEvidenceMs;
      int? inputs = ranking.inputTokens;
      int? outputs = ranking.outputTokens;
      var reason = 'exhausted_candidates';
      Future<_PendingFile> load(RankedFile candidate) async {
        final existing = loaded[candidate.path];
        if (existing != null) return existing;
        final file = _PendingFile(candidate.path);
        loaded[file.path] = file;
        if (prefetched.containsKey(file.path)) {
          file.evidence = prefetched[file.path];
          return file;
        }
        if (stop.isCancelled || readBytes >= maxReadBytes) {
          file.failure =
              'Reading stopped by cancellation or the run read budget.';
          return file;
        }
        final scan = await _untilCancelled(
          source.read(
            [file.path],
            stop,
            progress,
            maxBytes: maxReadBytes - readBytes,
          ),
          stop,
          EvidenceScan([], 0, ['Reading interrupted.']),
        );
        gaps.addAll(scan.gaps);
        scanned += scan.filesScanned;
        readBytes +=
            scan.bytesRead ??
            scan.evidence.fold<int>(
              0,
              (sum, e) => sum + utf8.encode(e.text).length,
            );
        final evidence = scan.evidence
            .where((e) => e.path == file.path)
            .firstOrNull;
        if (evidence == null) {
          file.failure =
              scan.readFailures[file.path] ??
              'File was unavailable or reading was interrupted.';
        } else {
          file.evidence = evidence;
        }
        return file;
      }

      void prepare(_PendingFile file) {
        if (file.prepared || file.evidence == null) return;
        file.prepared = true;
        try {
          file.chunks = chunker.split(file.evidence!, question);
        } on JudgmentException catch (e) {
          file.failure = 'Cannot pack file regions: ${e.failure.name}.';
        }
      }

      // An explicit rank-only request makes no content reads or judgments.
      // Auto may hand off a few complete small source files, labeled unverified.
      var handedOff = false;
      if (mode == ExplorationMode.rank) {
        reason = 'ranked_candidates';
      } else if (mode == ExplorationMode.auto &&
          ranking.complete &&
          candidates.isNotEmpty) {
        final strong = candidates
            .takeWhile((f) => f.inspectProbability! >= selectionThreshold)
            .toList();
        final clear =
            strong.isNotEmpty &&
            strong.length <= 3 &&
            strong.length <= maxResults &&
            (strong.length == candidates.length ||
                strong.last.inspectProbability! -
                        candidates[strong.length].inspectProbability! >=
                    0.2);
        if (clear) {
          final picked = <_PendingFile>[];
          var size = 0;
          for (final candidate in strong) {
            final file = await load(candidate);
            picked.add(file);
            size += file.evidence?.text.runes.length ?? 12001;
          }
          if (!stop.isCancelled &&
              size <= 12000 &&
              picked.every(
                (f) =>
                    f.evidence != null && f.evidence!.text.runes.length <= 6000,
              )) {
            for (final file in picked) {
              final text = file.evidence!.text;
              file.handoff = SourceExcerpt(
                1,
                1 +
                    '\n'.allMatches(text).length -
                    (text.endsWith('\n') ? 1 : 0),
                text,
                false,
              );
            }
            handedOff = true;
            firstEvidenceMs = watch.elapsedMilliseconds;
            reason = 'candidate_handoff';
          }
        }
      }
      if (mode != ExplorationMode.rank && !handedOff) {
        final active = Queue<_PendingFile>();
        var next = 0;
        final limits = runner.limits;
        while (!stop.isCancelled) {
          // Start with one wave of candidate files. Expand only when its regions
          // are inconclusive; a large file shares each wave with its peers.
          if (active.isEmpty) {
            while (next < candidates.length &&
                active.length < limits.concurrency &&
                !stop.isCancelled) {
              final file = await load(candidates[next++]);
              prepare(file);
              if (file.chunks.isNotEmpty) active.add(file);
              if (readBytes >= maxReadBytes) break;
            }
          }
          if (active.isEmpty) {
            if (readBytes >= maxReadBytes && next < candidates.length)
              reason = 'read_budget';
            break;
          }
          final wave = <(_PendingFile, EvidenceChunk)>[];
          while (active.isNotEmpty && wave.length < limits.concurrency) {
            final file = active.removeFirst();
            wave.add((file, file.chunks[file.next++]));
            if (file.next < file.chunks.length) active.addLast(file);
          }
          progress(
            'Exploring: checking ${wave.length} source regions; $matches useful files found',
          );
          final batch = await session.run(
            runner,
            [for (final entry in wave) entry.$2.request],
            tokenAllowance: limits.maxChargedTokens - contentCharge,
            requestAllowance: limits.maxRequests - contentRequests,
          );
          contentCacheHits += batch.items.where((i) => i.cached).length;
          contentCharge += batch.chargedTokens;
          var fatal = false;
          for (var i = 0; i < wave.length; i++) {
            final (file, chunk) = wave[i];
            final item = batch.items[i];
            if (item.attempted) contentRequests++;
            final result = item.result;
            if (result == null && item.attempted) {
              inputs = null;
              outputs = null;
            }
            double? probability;
            if (result != null && !item.cached) {
              inputs = inputs != null && result.usage.inputTokens != null
                  ? inputs + result.usage.inputTokens!
                  : null;
              outputs = outputs != null && result.usage.outputTokens != null
                  ? outputs + result.usage.outputTokens!
                  : null;
            }
            if (result != null)
              probability = result.answer(chunk.question).noul;
            final useful = probability != null && probability >= matchThreshold;
            file.regions.add(
              RegionJudgment(
                startLine: chunk.startLine,
                endLine: chunk.endLine,
                matchesProbability: probability,
                failure: item.failure,
                attempted: item.attempted,
                excerpt: useful && !file.matched && matches < maxResults
                    ? chunk.excerpt(maxScalars: 24000)
                    : null,
              ),
            );
            if (useful && !file.matched) {
              file.matched = true;
              matches++;
              firstEvidenceMs ??= watch.elapsedMilliseconds;
            }
            if (item.failure == JudgmentFailure.authentication ||
                item.failure == JudgmentFailure.permission)
              fatal = true;
          }
          active.removeWhere((f) => f.matched);
          if (matches >= maxResults) {
            reason = 'enough_evidence';
            break;
          }
          if (fatal) {
            reason = 'provider_failure';
            break;
          }
          if (batch.items.every(
            (i) => !i.attempted && i.failure == JudgmentFailure.budgetExceeded,
          )) {
            reason = 'content_budget';
            break;
          }
        }
      }
      if (stop.isCancelled) reason = timedOut ? 'deadline' : 'cancelled';
      if (candidates.isEmpty)
        gaps.add('No ranked candidates; this does not establish absence.');
      if (loaded.length < candidates.length)
        gaps.add(
          '${candidates.length - loaded.length} ranked files were not read.',
        );
      if (loaded.values.any(
        (f) =>
            f.failure != null ||
            f.regions.where((r) => r.matchesProbability != null).length <
                f.chunks.length,
      )) {
        gaps.add(
          'Some files or regions remain unchecked; no repository-wide absence claim is supported.',
        );
      }
      final status = stop.isCancelled
          ? (timedOut ? 'timeout' : 'cancelled')
          : reason == 'provider_failure' ||
                (candidates.isEmpty && !ranking.complete)
          ? 'failed'
          : !ranking.complete ||
                reason.endsWith('_budget') ||
                loaded.values.any(
                  (f) =>
                      f.failure != null ||
                      f.regions.any((r) => r.failure != null),
                )
          ? 'partial'
          : 'completed';
      progress(
        'Exploring: $reason; $contentRequests content requests in ${watch.elapsedMilliseconds}ms',
      );
      final result = ExplorationResult(
        status: status,
        stopReason: reason,
        ranking: ranking,
        files: loaded.values.map((f) => f.result),
        gaps: gaps.toSet(),
        filesScanned: scanned,
        contentChargedTokens: contentCharge,
        contentRequests: contentRequests,
        contentCacheHits: contentCacheHits,
        inputTokens: inputs,
        outputTokens: outputs,
        elapsedMs: watch.elapsedMilliseconds,
        firstEvidenceMs: firstEvidenceMs,
      );
      if (result.status == 'completed' && !stop.isCancelled) {
        await session.put(answerKey, {
          'question': question,
          'manifest_hash': manifestHash,
          'dependencies': {
            for (final f in loaded.values) f.path: f.contentHash,
          },
          'result': encodeExplorationSnapshot(result),
        });
      }
      if (ranking.cacheHits + contentCacheHits > 0) {
        progress(
          'Exploring: reused ${ranking.cacheHits} ranking and $contentCacheHits content judgments',
        );
      }
      return result;
    } finally {
      finished = true;
      timer.cancel();
      detach?.call();
    }
  }
}

class _PendingFile {
  final String path;
  ProjectEvidence? evidence;
  List<EvidenceChunk> chunks = [];
  final List<RegionJudgment> regions = [];
  String? failure;
  SourceExcerpt? handoff;
  int next = 0;
  bool matched = false;
  bool prepared = false;
  String? _contentHash;
  String get contentHash => _contentHash ??= evidenceHash(evidence!.text);
  _PendingFile(this.path);
  FileCheck get result => FileCheck(
    path: path,
    regions: regions,
    chunksTotal: chunks.length,
    readFailure: failure,
    unverifiedExcerpt: handoff,
  );
}

Future<T> _untilCancelled<T>(
  Future<T> operation,
  JudgmentCancellation stop,
  T fallback,
) async {
  final interrupted = Completer<T>();
  final detach = stop.listen(() => interrupted.complete(fallback));
  try {
    return await Future.any([operation, interrupted.future]);
  } finally {
    detach();
  }
}
