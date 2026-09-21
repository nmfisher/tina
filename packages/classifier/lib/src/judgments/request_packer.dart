import '../shared/range_packer.dart';
import 'service.dart';

/// Compatibility adapter: judgments retain their transport-facing failure type.
Iterable<T> packRequestRanges<T>({
  required int length,
  required int maxChunks,
  required T Function(int start, int end) build,
  required bool Function(T request) fits,
  required int Function(int start, int end) chooseEnd,
  int Function(int start, int end)? nextStart,
}) sync* {
  try {
    yield* packInputRanges(
      length: length,
      maxChunks: maxChunks,
      build: build,
      fits: fits,
      chooseEnd: chooseEnd,
      nextStart: nextStart,
    );
  } on InputTooLargeException {
    throw const JudgmentException(
      JudgmentFailure.requestTooLarge,
      attempted: false,
    );
  }
}
