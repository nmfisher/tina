import 'src/input/utterance_result.dart';
import 'src/input/classification_snapshot.dart';
export 'src/input/utterance_result.dart';
export 'src/input/classification_snapshot.dart';

enum ClassificationPhase {
  idle,
  checking,
  learning,
  ready,
  unavailable,
  cancelled,
}

final class ClassificationStatus {
  const ClassificationStatus(
    this.phase, {
    this.inputId,
    this.result,
    this.reason,
  });
  final ClassificationPhase phase;
  final String? inputId;
  final UtteranceClassification? result;
  final String? reason;
  String get label => switch (phase) {
    ClassificationPhase.idle => 'no input classified yet',
    ClassificationPhase.checking => 'classifying…',
    ClassificationPhase.learning => 'learning category…',
    ClassificationPhase.ready => result!.label,
    ClassificationPhase.unavailable => 'unavailable: $reason',
    ClassificationPhase.cancelled => 'cancelled',
  };
}

/// Read-only classification status and diagnostics.
abstract interface class ClassificationObservation {
  ClassificationStatus get status;
  ClassificationTraceSnapshot get trace;
  void Function() listen(void Function() changed);
}
