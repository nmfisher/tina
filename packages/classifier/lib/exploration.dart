/// Repository exploration: evidence models, ranking, chunking, caching,
/// snapshotting, and the judgment-driven exploration workflow.
///
/// Depends on `judgments.dart` only. The Typesafe transport that drives
/// the workflow lives in `typesafe_classifier.dart` (or any other
/// `JudgmentService` implementation).
library;

export 'src/exploration/models.dart';
export 'src/exploration/repository_ranker.dart';
export 'src/exploration/file_chunker.dart';
export 'src/exploration/exploration_cache.dart';
export 'src/exploration/exploration_snapshot.dart';
export 'src/exploration/exploration_workflow.dart';
