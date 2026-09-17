import 'package:tina_engine/judgments.dart';

/// Fresh evidence owned by Tina, never paths/excerpts invented by a model.
class ProjectEvidence {
  final String path;
  final int startLine;
  final String text;
  final int lexicalScore;
  const ProjectEvidence(
    this.path,
    this.startLine,
    this.text,
    this.lexicalScore,
  );
}

class EvidenceScan {
  final List<ProjectEvidence> evidence;
  final int filesScanned;
  final List<String> gaps;
  EvidenceScan(
    Iterable<ProjectEvidence> evidence,
    this.filesScanned,
    Iterable<String> gaps,
  ) : evidence = List.unmodifiable(evidence),
      gaps = List.unmodifiable(gaps);
}

abstract interface class ProjectEvidenceSource {
  Future<EvidenceScan> collect(
    String question,
    JudgmentCancellation cancellation,
    void Function(String) progress,
  );
}

class ExplorationFinding {
  final String path;
  final int startLine;
  final int endLine;
  final String excerpt;
  final double relevance;
  final double confidence;
  const ExplorationFinding({
    required this.path,
    required this.startLine,
    required this.endLine,
    required this.excerpt,
    required this.relevance,
    required this.confidence,
  });
  Map<String, Object> toJson() => {
    'path': path,
    'start_line': startLine,
    'end_line': endLine,
    'excerpt': excerpt,
    'relevance': relevance,
    'confidence': confidence,
  };
}

class ExplorationResult {
  final String status;
  final List<ExplorationFinding> findings;
  final List<String> gaps;
  final int filesScanned;
  final int chunksJudged;
  final int chargedTokens;
  final int? inputTokens;
  final int? outputTokens;
  ExplorationResult({
    required this.status,
    required Iterable<ExplorationFinding> findings,
    required Iterable<String> gaps,
    required this.filesScanned,
    required this.chunksJudged,
    required this.chargedTokens,
    required this.inputTokens,
    required this.outputTokens,
  }) : findings = List.unmodifiable(findings),
       gaps = List.unmodifiable(gaps);
  Map<String, Object?> toJson() => {
    'status': status,
    'findings': findings.map((f) => f.toJson()).toList(),
    'coverage': {
      'files_scanned': filesScanned,
      'chunks_judged': chunksJudged,
      'gaps': gaps,
      'exhaustive': false,
    },
    'usage': {
      'charged_tokens': chargedTokens,
      'input_tokens': inputTokens,
      'output_tokens': outputTokens,
    },
  };
}
