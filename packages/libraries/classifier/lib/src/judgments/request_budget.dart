import 'dart:convert';

import 'models.dart';
import 'service.dart';
import 'request_packer.dart';

/// Estimates the COMPLETE serialized request. Custom estimators must be
/// conservative and monotonic as evidence is added. The fallback charges one
/// token per UTF-8 byte: deliberately cautious for code and non-English text,
/// not a claim to reproduce the provider's unpublished tokenizer.
typedef JudgmentTokenEstimator = int Function(String serializedRequest);

class JudgmentRequestBudget {
  final String model;
  final int maxInputTokens;
  final int overheadTokens;
  final JudgmentTokenEstimator? estimator;

  /// 24k is a local operating target with headroom below the documented roughly
  /// 32k shared state/questions window. Pin/override it for other models.
  JudgmentRequestBudget({
    this.model = 'jev-latest',
    this.maxInputTokens = 24000,
    this.overheadTokens = 1024,
    this.estimator,
  }) {
    if (model.trim().isEmpty ||
        maxInputTokens <= overheadTokens ||
        overheadTokens < 0) {
      throw ArgumentError('Invalid judgment request budget');
    }
  }

  int estimate(JudgmentRequest request) {
    final json = jsonEncode(request.toJson(model: model));
    final count = estimator?.call(json) ?? utf8.encode(json).length;
    if (count < 0) throw StateError('Negative token estimate');
    return count + overheadTokens;
  }

  int check(JudgmentRequest request) {
    final tokens = estimate(request);
    if (tokens > maxInputTokens) {
      throw const JudgmentException(
        JudgmentFailure.requestTooLarge,
        attempted: false,
      );
    }
    return tokens;
  }

  /// Splits fresh textual evidence without dropping content. All question
  /// objects and their criteria remain intact in EVERY chunk: choice options
  /// are never silently partitioned and chunk probabilities are not merged.
  /// Prefer a newline boundary; oversized lines continue at Unicode boundaries.
  /// Offsets are Unicode scalar offsets, not bytes or UTF-16 code units.
  List<JudgmentEvidenceChunk> chunkText({
    required String source,
    required String text,
    required List<JudgmentQuestion> questions,
    int maxChunks = 256,
  }) {
    final runes = text.runes.toList();
    return List.unmodifiable(
      packRequestRanges<JudgmentEvidenceChunk>(
        length: runes.length,
        maxChunks: maxChunks,
        build: (start, end) => JudgmentEvidenceChunk(
          start,
          end,
          JudgmentRequest(
            state: {
              'source': source,
              'start_scalar': start,
              'end_scalar': end,
              'text': String.fromCharCodes(runes.sublist(start, end)),
            },
            questions: questions,
          ),
        ),
        fits: (chunk) => estimate(chunk.request) <= maxInputTokens,
        chooseEnd: (start, end) {
          for (var i = end - 1; i >= start; i--) {
            if (runes[i] == 10) return i + 1;
          }
          return end;
        },
      ),
    );
  }
}

class JudgmentEvidenceChunk {
  final int startScalar;
  final int endScalar;
  final JudgmentRequest request;
  const JudgmentEvidenceChunk(this.startScalar, this.endScalar, this.request);
}
