/// Schema migrations for the on-disk event log.
library;

/// One named, ordered transformation of the persisted state.
abstract interface class Migration {
  /// Unique, monotonically increasing version this migration produces.
  int get version;

  /// Human-readable description, shown in `track migrate --list`.
  String get description;

  /// Applies the migration to [lines] (raw JSON event lines).
  List<String> apply(List<String> lines);
}

/// Runs [migrations] in order up to [targetVersion].
///
/// Idempotent: migrations already reflected in [currentVersion] are
/// skipped, so this is safe to call on every startup.
List<String> runMigrations(
  List<String> lines,
  List<Migration> migrations, {
  required int currentVersion,
  int? targetVersion,
}) {
  final target = targetVersion ?? migrations.map((m) => m.version).max;
  var result = lines;
  for (final m in migrations.where((m) => m.version > currentVersion)) {
    if (m.version > target) break;
    result = m.apply(result);
  }
  return result;
}

extension on Iterable<int> {
  int get max => fold(0, (a, b) => a > b ? a : b);
}

/// v0 → v1: rewrites the legacy `"kind"` field to `"type"`.
final class KindToTypeMigration implements Migration {
  @override
  int get version => 1;

  @override
  String get description => 'rename event field "kind" to "type"';

  @override
  List<String> apply(List<String> lines) => lines; // no legacy data exists
}
