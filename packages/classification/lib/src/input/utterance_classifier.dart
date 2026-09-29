import 'package:tina_core/tina_core.dart';
import '../../judgments.dart';
import 'git_classifier.dart';
import 'intent_classifier.dart';

final class UtteranceClassification {
  const UtteranceClassification({required this.intent, this.git});
  final IntentResult intent;

  /// Absent when the utterance was not classified as an instruction.
  final GitIntent? git;
  Map<String, Object?> toJson() => {
    'intent': intent.toJson(),
    if (git != null) 'git': git!.toJson(),
  };
  String get label {
    final intentLabel = switch (intent.type) {
      IntentType.projectQuestion => 'project question',
      IntentType.agentInstruction => 'instruction',
      IntentType.unclear => 'unclear',
      null => 'neither question nor instruction',
    };
    final git = this.git;
    if (git == null) return intentLabel;
    return '$intentLabel · git: ${git.unknown
        ? 'unclear'
        : git.commands.isEmpty
        ? 'no'
        : git.commands.join(', ')}';
  }
}

/// Dependent stages: inspect Git operations only for a detected instruction.
/// Predictions do not execute commands or grant permission.
Future<UtteranceClassification> classifyUtterance({
  required String id,
  required String text,
  required List<Message> history,
  required JudgmentService service,
  required JudgmentRequestBudget budget,
  required JudgmentCancellation cancellation,
}) async {
  final source = InputTextSource(id, text, history);
  final intent = await classifyIntent(
    source: source,
    service: service,
    budget: budget,
    cancellation: cancellation,
  );
  if (cancellation.isCancelled)
    throw const JudgmentException(JudgmentFailure.cancelled);
  final git = intent.type == IntentType.agentInstruction
      ? await classifyGitInput(
          source: source,
          service: service,
          budget: budget,
          cancellation: cancellation,
        )
      : null;
  return UtteranceClassification(intent: intent, git: git);
}
