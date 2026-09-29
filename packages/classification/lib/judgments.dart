/// Structured judgments, independent of chat providers and agent execution.
///
/// Pure question/answer models, request budgeting, and batch execution.
/// The network-bound Typesafe service lives in `typesafe_classifier.dart`;
/// import that instead when you need to talk to the Typesafe endpoint.
library;

export 'src/judgments/models.dart';
export 'src/judgments/service.dart';
export 'src/judgments/request_budget.dart';
export 'src/judgments/batch_runner.dart';
