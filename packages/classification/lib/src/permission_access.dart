/// Filesystem effects identified during permission review. Model assessments
/// describe the request; they never authorize access or certify a command.
enum PermissionAccessOperation { read, create, write, delete, move }

enum PermissionTargetKind { file, directory, unknown }

enum PermissionAccessCoverage { complete, partial, unknown }

final class PermissionAccess {
  const PermissionAccess(this.operation, this.path, this.targetKind);
  final PermissionAccessOperation operation;
  final String path;
  final PermissionTargetKind targetKind;

  Map<String, Object?> toJson() => {
    'operation': operation.name,
    'path': path,
    'target_kind': targetKind.name,
  };

  static PermissionAccess fromJson(Object? raw) {
    if (raw is! Map ||
        raw.length != 3 ||
        raw['path'] is! String ||
        (raw['path'] as String).trim().isEmpty ||
        (raw['path'] as String).length > 4096 ||
        RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(raw['path'] as String)) {
      throw const FormatException('Invalid permission access');
    }
    return PermissionAccess(
      PermissionAccessOperation.values.byName(raw['operation'] as String),
      raw['path'] as String,
      PermissionTargetKind.values.byName(raw['target_kind'] as String),
    );
  }
}

final class PermissionAccessAssessment {
  const PermissionAccessAssessment({
    this.accesses = const [],
    this.coverage = PermissionAccessCoverage.unknown,
    this.unresolved = const [],
  });
  final List<PermissionAccess> accesses;
  final PermissionAccessCoverage coverage;
  final List<String> unresolved;

  Map<String, Object?> toJson() => {
    'accesses': accesses.map((access) => access.toJson()).toList(),
    'coverage': coverage.name,
    'unresolved': unresolved,
  };

  static PermissionAccessAssessment fromJson(Map<String, dynamic> raw) {
    // Older endpoints may return the original two-field verdict. Its absence
    // of access details means unknown, never an empty complete assessment.
    if (raw.length == 2) return const PermissionAccessAssessment();
    if (raw.length != 5 ||
        raw['accesses'] is! List ||
        (raw['accesses'] as List).length > 64 ||
        raw['unresolved'] is! List ||
        (raw['unresolved'] as List).length > 16) {
      throw const FormatException('Invalid permission assessment');
    }
    final coverage = PermissionAccessCoverage.values.byName(
      raw['coverage'] as String,
    );
    final unresolved = <String>[];
    for (final value in raw['unresolved'] as List) {
      if (value is! String ||
          value.trim().isEmpty ||
          value.length > 240 ||
          RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value)) {
        throw const FormatException('Invalid unresolved access');
      }
      unresolved.add(value);
    }
    if (coverage == PermissionAccessCoverage.complete &&
        unresolved.isNotEmpty) {
      throw const FormatException('Complete assessment has unresolved access');
    }
    return PermissionAccessAssessment(
      accesses: List.unmodifiable(
        (raw['accesses'] as List).map(PermissionAccess.fromJson),
      ),
      coverage: coverage,
      unresolved: List.unmodifiable(unresolved),
    );
  }
}
