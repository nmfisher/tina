import 'dart:convert';

import 'models.dart';
import 'service.dart';

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
      throw const JudgmentException(JudgmentFailure.requestTooLarge);
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
    if (maxChunks <= 0) throw ArgumentError.value(maxChunks, 'maxChunks');
    final runes = text.runes.toList();
    final chunks = <JudgmentEvidenceChunk>[];
    var start = 0;
    JudgmentRequest request(int end) => JudgmentRequest(state: {
          'source': source,
          'start_scalar': start,
          'end_scalar': end,
          'text': String.fromCharCodes(runes.sublist(start, end)),
        }, questions: questions);
    do {
      if (chunks.length == maxChunks) {
        throw const JudgmentException(JudgmentFailure.requestTooLarge);
      }
      check(request(start)); // Fail when questions/metadata alone cannot fit.
      var low = start;
      var high = runes.length;
      while (low < high) {
        final mid = (low + high + 1) ~/ 2;
        if (estimate(request(mid)) <= maxInputTokens) {
          low = mid;
        } else {
          high = mid - 1;
        }
      }
      var end = low;
      if (end == start && start < runes.length) {
        throw const JudgmentException(JudgmentFailure.requestTooLarge);
      }
      if (end < runes.length) {
        for (var i = end - 1; i >= start; i--) {
          if (runes[i] == 10) {
            end = i + 1;
            break;
          }
        }
      }
      final packed = request(end);
      check(packed);
      chunks.add(JudgmentEvidenceChunk(start, end, packed));
      start = end;
    } while (start < runes.length);
    return List.unmodifiable(chunks);
  }
}

class JudgmentEvidenceChunk {
  final int startScalar;
  final int endScalar;
  final JudgmentRequest request;
  const JudgmentEvidenceChunk(this.startScalar, this.endScalar, this.request);
}
