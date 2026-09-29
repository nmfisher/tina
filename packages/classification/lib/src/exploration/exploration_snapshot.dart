import '../judgments/service.dart' show JudgmentFailure;
import 'models.dart';

/// Internal full-fidelity snapshot, independent of the compact chat handoff.
Map<String, dynamic> encodeExplorationSnapshot(ExplorationResult result) => {
  'status': result.status,
  'stop_reason': result.stopReason,
  'ranking': result.ranking.files.map((f) => f.toJson()).toList(),
  'files': [
    for (final file in result.files)
      {
        ...file.toJson(),
        'regions': file.regions.map((r) => r.toJson()).toList(),
      },
  ],
  'gaps': result.gaps,
  'original_usage': result.toJson()['usage'],
  'metadata_judgments': result.ranking.requests + result.ranking.cacheHits,
  'content_judgments': result.contentRequests + result.contentCacheHits,
};

ExplorationResult decodeExplorationSnapshot(
  Map<String, dynamic> json, {
  required Set<String> expectedPaths,
  required Set<String> dependencies,
  required int filesScanned,
  required int elapsedMs,
}) {
  if (json['status'] != 'completed')
    throw const FormatException('Incomplete snapshot');
  final ranking = (json['ranking'] as List).map((raw) {
    final f = Map<String, dynamic>.from(raw as Map);
    return RankedFile(
      f['id'] as int,
      f['path'] as String,
      inspectProbability: _probability(f['inspect_probability']),
      failure: _failure(f['failure']),
    );
  }).toList();
  if (ranking.length != expectedPaths.length ||
      ranking.map((f) => f.path).toSet().length != expectedPaths.length ||
      ranking.any(
        (f) => !expectedPaths.contains(f.path) || f.failure != null,
      )) {
    throw const FormatException('Manifest mismatch');
  }
  final files = (json['files'] as List).map((raw) {
    final f = Map<String, dynamic>.from(raw as Map);
    final path = f['path'] as String;
    if (!dependencies.contains(path))
      throw const FormatException('Unvalidated source');
    return FileCheck(
      path: path,
      chunksTotal: f['chunks_total'] as int,
      readFailure: f['read_failure'] as String?,
      unverifiedExcerpt: _excerpt(f['excerpt']),
      regions: (f['regions'] as List).map((raw) {
        final r = raw as Map;
        return RegionJudgment(
          startLine: r['start_line'] as int,
          endLine: r['end_line'] as int,
          matchesProbability: _probability(r['matches_probability']),
          failure: _failure(r['failure']),
          attempted: false,
          excerpt: _excerpt(r['excerpt']),
        );
      }),
    );
  }).toList();
  if (files.map((f) => f.path).toSet().length != dependencies.length) {
    throw const FormatException('Missing dependencies');
  }
  return ExplorationResult(
    status: 'completed',
    stopReason: json['stop_reason'] as String,
    ranking: RankingResult(
      files: ranking,
      chargedTokens: 0,
      requests: 0,
      inputTokens: 0,
      outputTokens: 0,
      cacheHits: json['metadata_judgments'] as int,
    ),
    files: files,
    gaps: (json['gaps'] as List).cast<String>(),
    filesScanned: filesScanned,
    contentChargedTokens: 0,
    contentRequests: 0,
    inputTokens: 0,
    outputTokens: 0,
    contentCacheHits: json['content_judgments'] as int,
    answerCacheHit: true,
    elapsedMs: elapsedMs,
    firstEvidenceMs: files.any((f) => f.hasEvidence) ? elapsedMs : null,
  );
}

double? _probability(Object? value) {
  if (value == null) return null;
  final probability = (value as num).toDouble();
  if (!probability.isFinite || probability < 0 || probability > 1)
    throw const FormatException('Invalid probability');
  return probability;
}

JudgmentFailure? _failure(Object? value) =>
    value == null ? null : JudgmentFailure.values.byName(value as String);
SourceExcerpt? _excerpt(Object? value) {
  if (value == null) return null;
  final json = value as Map;
  return SourceExcerpt(
    json['start_line'] as int,
    json['end_line'] as int,
    json['text'] as String,
    json['truncated'] as bool,
  );
}
