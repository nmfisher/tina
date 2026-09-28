import '../judgments/service.dart' show JudgmentCancellation;
import '../shared/range_packer.dart';
import 'models.dart';

/// Collectors can share a raw representation while independently selecting how
/// it is presented. An encoder/visitor lives with the source, never the agent.
abstract interface class InputEncoder<R, I> {
  Object get identity;
  I encode(R raw);
}

abstract interface class ClassificationSource<I> {
  Object get identity;
  DataContract<I> get contract;
  InputSplitter<I>? get splitter;
  Future<SourceSnapshot<I>> snapshot(
    SourceRequest request,
    JudgmentCancellation cancellation,
  );
  Future<bool> isCurrent(
    SourceRevision revision,
    JudgmentCancellation cancellation,
  );
}

class SourceSnapshot<I> {
  final List<SourceUnit<I>> units;
  final SourceRevision revision;
  final InputCoverage coverage;
  final InputSplitter<I>? splitter;
  SourceSnapshot({
    required Iterable<SourceUnit<I>> units,
    required this.revision,
    required this.coverage,
    this.splitter,
  }) : units = List.unmodifiable(units) {
    if (this.units.map((u) => u.id).toSet().length != this.units.length)
      throw ArgumentError('Duplicate source unit IDs');
  }
}

/// Source-selected splitting policy. `fits` budgets the complete model request.
/// Implementations must preserve all content and stable evidence locations.
abstract interface class InputSplitter<I> {
  Object get identity;
  Iterable<SourceUnit<I>> split(
    SourceUnit<I> unit,
    bool Function(SourceUnit<I>) fits,
    int maxParts,
  );
}

/// Shared text implementation; prefers complete lines, falling back to Unicode
/// scalar boundaries. Atomic sources simply omit a splitter.
class TextInputSplitter implements InputSplitter<TextEvidence> {
  const TextInputSplitter();
  @override
  Object get identity => {'id': 'classifier.text_splitter', 'revision': 1};
  @override
  Iterable<SourceUnit<TextEvidence>> split(
    SourceUnit<TextEvidence> unit,
    bool Function(SourceUnit<TextEvidence>) fits,
    int maxParts,
  ) {
    final scalars = unit.value.text.runes.toList();
    return packInputRanges(
      length: scalars.length,
      maxChunks: maxParts,
      build: (start, end) => SourceUnit(
        '${unit.id}@$start:$end',
        TextEvidence(
          '${unit.value.meaning} (excerpt)',
          String.fromCharCodes(scalars.sublist(start, end)),
        ),
        location: {
          ...unit.location,
          'origin': unit.id,
          'start_scalar': start,
          'end_scalar': end,
        },
        supportingEvidence: unit.supportingEvidence,
      ),
      fits: fits,
      chooseEnd: (start, end) {
        for (var i = end - 1; i > start; i--) {
          if (scalars[i] == 10) return i + 1;
        }
        return end;
      },
    );
  }
}
