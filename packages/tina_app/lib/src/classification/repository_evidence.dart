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

class ClassificationScope {
  final String path;
  final String? parent;
  ClassificationScope(this.path, {this.parent}) {
    if (!validProjectPath(path) ||
        (parent != null &&
            (!validProjectPath(parent!) ||
                parent == path ||
                !insideScope(path, parent!)))) {
      throw ArgumentError('Invalid classification scope');
    }
  }
  Map<String, Object?> toJson() => {'path': path, 'parent': parent};
}

List<ClassificationScope> classificationScopes(Iterable<String> discovered) {
  final paths = {'.', ...discovered}.toList()..sort();
  if (paths.length > 256 || paths.any((p) => !validProjectPath(p))) {
    throw const FormatException('Invalid discovered scopes');
  }
  return [
    for (final path in paths)
      ClassificationScope(
        path,
        parent: path == '.'
            ? null
            : (paths.where((p) => p != path && insideScope(path, p)).toList()
                    ..sort(
                      (a, b) => (b == '.' ? 0 : b.length).compareTo(
                        a == '.' ? 0 : a.length,
                      ),
                    ))
                  .first,
      ),
  ];
}

enum EvidenceKind { file, listing }

class EvidenceQuery {
  final EvidenceKind kind;
  final String path;
  final List<String> excludedScopes;
  EvidenceQuery(
    this.kind,
    this.path, {
    Iterable<String> excludedScopes = const [],
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
  };
  factory EvidenceQuery.fromJson(Map<String, dynamic> json) => EvidenceQuery(
    EvidenceKind.values.byName(json['kind'] as String),
    json['path'] as String,
    excludedScopes: (json['excluded_scopes'] as List).cast<String>(),
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
