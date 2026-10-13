import 'src/working_context.dart';
export 'src/working_context.dart';

final class ContextBudgetUsage {
  const ContextBudgetUsage({
    required this.inputTokens,
    required this.budgetTokens,
    required this.responseReserveTokens,
    required this.reminder,
  });
  final int inputTokens, budgetTokens, responseReserveTokens;
  final String? reminder;
  int get inputLimit => budgetTokens - responseReserveTokens;

  /// Signed: a negative value means the estimated request exceeds its allowance.
  int get remainingInputTokens => inputLimit - inputTokens;
  double get fractionUsed => inputTokens / budgetTokens;
}

enum ContextEditStatus { unchanged, accepted, rejected }

final class ContextEditReceipt {
  const ContextEditReceipt(this.status, this.message);
  final ContextEditStatus status;
  final String message;
}

/// Accepted context and public editing status, without file or runtime access.
abstract interface class ContextObservation {
  void refresh();
  bool get includePendingTurn;
  WorkingContext get workingContext;
  ContextBudgetUsage? get budgetUsage;
  int get budgetTokens;
  int? get latestEditTokensSaved;
  String get fileStatus;
  String? get mirrorPath;
  ContextEditReceipt? get lastEditReceipt;
  ({WorkingContext before, WorkingContextSnapshot after})? get latestChange;
}
