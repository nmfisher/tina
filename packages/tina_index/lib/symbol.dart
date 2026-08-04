enum SymbolKind {
  class_,
  mixin,
  enum_,
  extension,
  function,
  method,
  field,
}

class Symbol {
  final String name;
  final SymbolKind kind;
  final String filePath;
  final int lineStart;
  final int lineEnd;
  final String? parentName;
  final bool isAbstract;

  const Symbol({
    required this.name,
    required this.kind,
    required this.filePath,
    required this.lineStart,
    required this.lineEnd,
    this.parentName,
    this.isAbstract = false,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'kind': kind.name,
        'filePath': filePath,
        'lineStart': lineStart,
        'lineEnd': lineEnd,
        if (parentName != null) 'parentName': parentName,
        if (isAbstract) 'isAbstract': isAbstract,
      };

  static Symbol fromJson(Map<String, dynamic> json) => Symbol(
        name: json['name'] as String,
        kind: SymbolKind.values.byName(json['kind'] as String),
        filePath: json['filePath'] as String,
        lineStart: json['lineStart'] as int,
        lineEnd: json['lineEnd'] as int,
        parentName: json['parentName'] as String?,
        isAbstract: json['isAbstract'] as bool? ?? false,
      );
}
