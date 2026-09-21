import 'package:classifier/classification.dart' show canonicalFingerprint;

bool validProjectPath(String path, {bool root = true}) =>
    (root && path == '.') ||
    (path.isNotEmpty &&
        !path.contains('\\') &&
        !path.contains(':') &&
        !path.contains('\u0000') &&
        path.split('/').every((p) => p.isNotEmpty && p != '.' && p != '..'));

bool insideScope(String path, String scope) =>
    scope == '.' || path == scope || path.startsWith('$scope/');

enum EvidenceKind { file, listing }

class EvidenceQuery {
  final EvidenceKind kind;
  final String path;
  final List<String> excludedScopes;
  final bool directOnly;
  EvidenceQuery(
    this.kind,
    this.path, {
    Iterable<String> excludedScopes = const [],
    this.directOnly = false,
  }) : excludedScopes = List.unmodifiable(excludedScopes.toList()..sort()) {
    if (!validProjectPath(path, root: kind == EvidenceKind.listing) ||
        this.excludedScopes.any((p) => !validProjectPath(p))) {
      throw const FormatException('Invalid evidence query');
    }
  }
  String get id => '${kind.name}:$path';
  Map<String, Object?> toJson() => {
    'kind': kind.name,
    'path': path,
    'excluded_scopes': excludedScopes,
    'direct_only': directOnly,
  };
  factory EvidenceQuery.fromJson(Map<String, dynamic> json) => EvidenceQuery(
    EvidenceKind.values.byName(json['kind'] as String),
    json['path'] as String,
    excludedScopes: (json['excluded_scopes'] as List).cast<String>(),
    directOnly: json['direct_only'] as bool? ?? false,
  );
}

class EvidenceRead {
  /// File text, null for an absent file, or a sorted list of repository paths.
  final Object? value;
  final String fingerprint;
  EvidenceRead(this.value) : fingerprint = canonicalFingerprint(value);
}

class EvidenceDependency {
  final EvidenceQuery query;
  final String fingerprint;
  EvidenceDependency(this.query, this.fingerprint);
  Map<String, Object?> toJson() => {
    'query': query.toJson(),
    'fingerprint': fingerprint,
  };
  factory EvidenceDependency.fromJson(Map<String, dynamic> json) =>
      EvidenceDependency(
        EvidenceQuery.fromJson(Map<String, dynamic>.from(json['query'] as Map)),
        json['fingerprint'] as String,
      );
}
