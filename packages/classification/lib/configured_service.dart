import 'config.dart';
import 'judgments.dart';
import 'typesafe_classifier.dart';

ClassificationLease? openConfiguredClassification(
  String configPath, {
  Map<String, String>? environment,
  Duration? timeout,
}) {
  final config = readClassificationConfig(
    configPath,
    environment: environment,
    timeout: timeout,
  );
  if (config == null) return null;
  final service = TypeSafeJudgmentService(config: config);
  return ClassificationLease(
    service: service,
    budget: config.requestBudget,
    close: service.close,
  );
}

/// One operation's classifier service. The caller owns and closes the lease.
final class ClassificationLease {
  ClassificationLease({
    required this.service,
    required this.budget,
    required this.close,
  });
  final JudgmentService service;
  final JudgmentRequestBudget budget;
  final void Function() close;
}
