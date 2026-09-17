import 'package:tina_engine/judgments.dart';

class ProjectEvidence {
  final String path;
  final String text;
  const ProjectEvidence(this.path, this.text);
}

class EvidenceScan {
  final List<ProjectEvidence> evidence;
  final int filesScanned;
  final List<String> gaps;
  final Map<String, String> readFailures;
  final int? bytesRead;
  EvidenceScan(
    Iterable<ProjectEvidence> evidence,
    this.filesScanned,
    Iterable<String> gaps, {
    Map<String, String> readFailures = const {},
    this.bytesRead,
  }) : evidence = List.unmodifiable(evidence),
       gaps = List.unmodifiable(gaps),
       readFailures = Map.unmodifiable(readFailures);
}

/// A metadata-only, normalized snapshot; stable file IDs are indices in paths.
class ProjectTree {
  final List<String> paths;
  final List<String> gaps;
  ProjectTree(Iterable<String> paths, Iterable<String> gaps)
    : paths = List.unmodifiable(paths.toSet().toList()..sort()),
      gaps = List.unmodifiable(gaps) {
    for (final path in this.paths) {
      if (path.contains('\\') ||
          path
              .split('/')
              .any((part) => part.isEmpty || part == '.' || part == '..')) {
        throw ArgumentError('Tree paths must be relative and normalized');
      }
    }
  }
}

abstract interface class ProjectEvidenceSource {
  Future<ProjectTree> enumerate(
    JudgmentCancellation cancellation,
    void Function(String) progress,
  );
  Future<EvidenceScan> read(
    List<String> paths,
    JudgmentCancellation cancellation,
    void Function(String) progress, {
    int? maxBytes,
  });
}

enum ExplorationMode { auto, verify, rank }

class RankedFile {
  final int id;
  final String path;
  final double? inspectProbability;
  final JudgmentFailure? failure;
  const RankedFile(this.id, this.path, {this.inspectProbability, this.failure});
  Map<String, Object?> toJson() => {
    'id': id,
    'path': path,
    if (inspectProbability != null) 'inspect_probability': inspectProbability,
    if (failure != null) 'failure': failure!.name,
  };
}

class RankingResult {
  final List<RankedFile> files;
  final int chargedTokens;
  final int requests;
  final int cacheHits;
  final int? inputTokens;
  final int? outputTokens;
  RankingResult({
    required Iterable<RankedFile> files,
    required this.chargedTokens,
    required this.requests,
    this.cacheHits = 0,
    required this.inputTokens,
    required this.outputTokens,
  }) : files = List.unmodifiable(files);
  bool get complete => files.every((f) => f.failure == null);
  List<RankedFile> get candidates =>
      files.where((f) => f.inspectProbability != null).toList()..sort((a, b) {
        final score = b.inspectProbability!.compareTo(a.inspectProbability!);
        return score != 0 ? score : a.path.compareTo(b.path);
      });
}

/// Text and locations are copied from the local snapshot, never generated.
class SourceExcerpt {
  final int startLine;
  final int endLine;
  final String text;
  final bool truncated;
  const SourceExcerpt(this.startLine, this.endLine, this.text, this.truncated);
  Map<String, Object?> toJson() => {
    'start_line': startLine,
    'end_line': endLine,
    'text': text,
    'truncated': truncated,
  };
}

class RegionJudgment {
  final int startLine;
  final int endLine;
  final double? matchesProbability;
  final JudgmentFailure? failure;
  final bool attempted;
  final SourceExcerpt? excerpt;
  const RegionJudgment({
    required this.startLine,
    required this.endLine,
    this.matchesProbability,
    this.failure,
    required this.attempted,
    this.excerpt,
  });
  Map<String, Object?> toJson() => {
    'start_line': startLine,
    'end_line': endLine,
    if (matchesProbability != null) 'matches_probability': matchesProbability,
    if (failure != null) 'failure': failure!.name,
    'attempted': attempted,
    if (excerpt != null) 'excerpt': excerpt!.toJson(),
  };
}

class FileCheck {
  final String path;
  final List<RegionJudgment> regions;
  final int chunksTotal;
  final String? readFailure;
  final SourceExcerpt? unverifiedExcerpt;
  FileCheck({
    required this.path,
    required Iterable<RegionJudgment> regions,
    required this.chunksTotal,
    this.readFailure,
    this.unverifiedExcerpt,
  }) : regions = List.unmodifiable(regions);
  bool get hasEvidence =>
      unverifiedExcerpt != null || regions.any((r) => r.excerpt != null);
  List<RegionJudgment> get reportedRegions => [
    ...regions.where((r) => r.excerpt != null),
    ...regions.where((r) => r.excerpt == null && r.failure != null),
    ...regions.where((r) => r.excerpt == null && r.failure == null),
  ].take(8).toList();
  int get chunksJudged =>
      regions.where((r) => r.matchesProbability != null).length;
  Map<String, Object?> toJson() => {
    'path': path,
    'chunks_total': chunksTotal,
    'chunks_judged': chunksJudged,
    'content_complete':
        readFailure == null && chunksTotal > 0 && chunksJudged == chunksTotal,
    if (readFailure != null) 'read_failure': readFailure,
    if (unverifiedExcerpt != null) ...{
      'verification': 'not_requested',
      'excerpt': unverifiedExcerpt!.toJson(),
    },
    'regions': reportedRegions.map((r) => r.toJson()).toList(),
    'regions_omitted': regions.length - reportedRegions.length,
  };
}

class ExplorationResult {
  final String status;
  final String stopReason;
  final RankingResult ranking;
  final List<FileCheck> files;
  final List<String> gaps;
  final int filesScanned;
  final int contentChargedTokens;
  final int contentRequests;
  final int contentCacheHits;
  final bool answerCacheHit;
  final int? inputTokens;
  final int? outputTokens;
  final int elapsedMs;
  final int? firstEvidenceMs;
  List<FileCheck> get reportedFiles => [
    ...files.where((f) => f.hasEvidence),
    ...files.where((f) => !f.hasEvidence),
  ].take(12).toList();
  int get chargedTokens => ranking.chargedTokens + contentChargedTokens;
  ExplorationResult({
    required this.status,
    required this.stopReason,
    required this.ranking,
    required Iterable<FileCheck> files,
    required Iterable<String> gaps,
    required this.filesScanned,
    required this.contentChargedTokens,
    required this.contentRequests,
    this.contentCacheHits = 0,
    this.answerCacheHit = false,
    required this.inputTokens,
    required this.outputTokens,
    required this.elapsedMs,
    required this.firstEvidenceMs,
  }) : files = List.unmodifiable(files),
       gaps = List.unmodifiable(gaps);
  Map<String, Object?> toJson() => {
    'status': status, 'stop_reason': stopReason,
    'cache': {
      'answer_hit': answerCacheHit,
      'metadata_hits': ranking.cacheHits,
      'content_hits': contentCacheHits,
    },
    // Bound the handoff to the chat agent; all file scores stay in the filter.
    'candidates': ranking.candidates.take(8).map((f) => f.toJson()).toList(),
    'ranking': {
      'complete': ranking.complete,
      'files_enumerated': ranking.files.length,
      'files_ranked': ranking.candidates.length,
      'failures': ranking.files
          .where((f) => f.failure != null)
          .take(8)
          .map((f) => f.toJson())
          .toList(),
      'files_unranked': ranking.files.where((f) => f.failure != null).length,
    },
    'files': reportedFiles.map((f) => f.toJson()).toList(),
    'coverage': {
      'files_scanned': filesScanned,
      'file_results_omitted': files.length - reportedFiles.length,
      'files_deferred': ranking.candidates.length - files.length,
      'gaps': gaps,
      'exhaustive': false,
    },
    'usage': {
      'charged_tokens': chargedTokens,
      'metadata_charged_tokens': ranking.chargedTokens,
      'content_charged_tokens': contentChargedTokens,
      'input_tokens': inputTokens,
      'output_tokens': outputTokens,
      'metadata_requests': ranking.requests,
      'content_requests': contentRequests,
    },
    'timing': {'elapsed_ms': elapsedMs, 'first_evidence_ms': firstEvidenceMs},
  };
}
