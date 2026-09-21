import 'dart:async';
import 'dart:convert';
import 'package:classifier/exploration.dart';
import 'package:classifier/judgments.dart';

class Source implements ProjectEvidenceSource {
  final List<ProjectEvidence> evidence;
  final List<List<String>> reads = [];
  final List<int?> allowances = [];
  Source(this.evidence);
  @override
  Future<ProjectTree> enumerate(
    JudgmentCancellation c,
    void Function(String) progress,
  ) async => ProjectTree(evidence.map((e) => e.path), []);
  @override
  Future<EvidenceScan> read(
    List<String> paths,
    JudgmentCancellation c,
    void Function(String) progress, {
    int? maxBytes,
  }) async {
    reads.add(paths);
    allowances.add(maxBytes);
    final found = evidence.where((e) => paths.contains(e.path)).toList();
    final bytes = found.fold<int>(
      0,
      (sum, f) => sum + utf8.encode(f.text).length,
    );
    return maxBytes != null && bytes > maxBytes
        ? EvidenceScan(
            [],
            0,
            [],
            readFailures: {
              for (final path in paths) path: 'Read budget exceeded.',
            },
          )
        : EvidenceScan(found, found.length, [], bytesRead: bytes);
  }
}

class Judge implements JudgmentService {
  final List<JudgmentRequest> requests = [];
  Future<JudgmentResult> Function(JudgmentRequest, JudgmentCancellation?)?
  handler;
  Future<JudgmentResult> Function(JudgmentRequest, JudgmentCancellation?)?
  metadataHandler;
  List<JudgmentRequest> get contentRequests => requests
      .where((r) => (r.state.value as Map)['phase'] == 'content_check')
      .toList();
  List<JudgmentRequest> get metadataRequests => requests
      .where((r) => (r.state.value as Map)['phase'] == 'file_ranking')
      .toList();
  @override
  Future<JudgmentResult> evaluate(
    JudgmentRequest r, {
    JudgmentCancellation? cancellation,
  }) {
    requests.add(r);
    if ((r.state.value as Map)['phase'] == 'file_ranking') {
      return metadataHandler?.call(r, cancellation) ??
          Future.value(answer(r, probability: 0.7));
    }
    return handler?.call(r, cancellation) ?? Future.value(answer(r));
  }

  JudgmentResult answer(JudgmentRequest r, {double probability = 0.9}) =>
      JudgmentResult.fromJson({
        'model': 'jev-latest',
        'answers': {
          for (final id in r.questions.keys)
            id: {'type': 'noul', 'noul': probability},
        },
        'usage': {'input_tokens': 200, 'output_tokens': 20},
      }, request: r);
}

ExplorationWorkflow workflow(ProjectEvidenceSource source, Judge judge) =>
    ExplorationWorkflow(
      source: source,
      runner: JudgmentBatchRunner(
        service: judge,
        budget: JudgmentRequestBudget(),
        limits: JudgmentBatchLimits(
          maxChargedTokens: 100000,
          outputTokenAllowance: 100,
        ),
      ),
    );
