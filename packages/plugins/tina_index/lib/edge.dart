enum EdgeKind {
  extends_,
  implements_,
  mixesIn,
  imports,
  exports,
}

class Edge {
  final String fromId;
  final String toId;
  final EdgeKind kind;

  const Edge({
    required this.fromId,
    required this.toId,
    required this.kind,
  });

  Map<String, dynamic> toJson() => {
        'fromId': fromId,
        'toId': toId,
        'kind': kind.name,
      };

  static Edge fromJson(Map<String, dynamic> json) => Edge(
        fromId: json['fromId'] as String,
        toId: json['toId'] as String,
        kind: EdgeKind.values.byName(json['kind'] as String),
      );

  @override
  String toString() => '$fromId —${kind.name}→ $toId';
}
