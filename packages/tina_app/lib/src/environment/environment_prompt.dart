import 'package:tina_app/src/environment/environment_record.dart';
import 'package:tina_app/src/environment/environment_store.dart';

/// The warm-load block for the system prompt's `<environment>` funnel: the
/// record's claims as compact lines plus the machine-rendered `status:`
/// verdict. Null when there is no record (nothing to load), when it is
/// unreadable, or on any read failure — a bad record must never break prompt
/// assembly.
String? projectEnvironmentBlock(String projectRoot) {
  final record = EnvironmentRecord.load(projectRoot);
  if (record == null) return null;
  final reason = EnvironmentTrackingStore(
    projectRoot: projectRoot,
  ).staleReason();
  final block = record.promptBlock(stale: reason != null, staleReason: reason);
  return block.isEmpty ? null : block;
}
