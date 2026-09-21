/// Scoped classifier-agent jobs, evidence tracking and incremental restoration.
/// Runtime agents and filesystem adapters are supplied by the application.
library;

export 'src/classification/models.dart';
export 'src/classification/definitions.dart';
export 'src/classification/evidence.dart';
export 'src/classification/store.dart';
export 'src/classification/orchestrator.dart';
export 'src/shared/fingerprint.dart';
export 'src/classification/planning.dart';
export 'src/shared/range_packer.dart' show InputTooLargeException;
