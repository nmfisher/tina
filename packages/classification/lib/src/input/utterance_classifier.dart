import 'utterance_result.dart';
export 'utterance_result.dart' show UtteranceClassification;
import 'package:tina_core/tina_core.dart';
import '../../judgments.dart';
import 'git_classifier.dart';
import 'intent_classifier.dart';

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
